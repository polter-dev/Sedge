import Foundation

/// Answers one question by letting a model call the read-only tools. The model sees only
/// what the tools return, never the raw transactions, and must end with `final_answer`.
public struct Assistant: Sendable {
    /// Most data-tool calls allowed per question (`final_answer` doesn't count).
    public static let maxToolCalls = 6

    public let backend: any ModelBackend
    public let database: SedgeDatabase

    public init(backend: any ModelBackend, database: SedgeDatabase) {
        self.backend = backend
        self.database = database
    }

    /// Never throws: a network failure, a refusal or a bad reply is written into the
    /// trace's `error`, so one broken question can't stop a run of a hundred.
    public func ask(_ question: String) async -> Trace {
        let start = ContinuousClock.now
        var trace = Trace(question: question, model: backend.model, effort: backend.effort, promptVersion: SystemPrompt.version)
        do {
            try await run(question, into: &trace)
        } catch {
            trace.error = "\(error)"
        }
        trace.latencySeconds = (ContinuousClock.now - start) / .seconds(1)
        return trace
    }

    private func run(_ question: String, into trace: inout Trace) async throws {
        guard let asOf = try database.asOf() else { throw AssistantError("No data has been loaded.") }
        let system = SystemPrompt.text(asOf: asOf)
        var messages: [ModelMessage] = [.user(question)]
        var callsLeft = Self.maxToolCalls

        // Worst case is one call per reply: six replies with calls, one more whose calls are
        // refused for being over the limit, and a last chance to call final_answer.
        for _ in 0..<(Self.maxToolCalls + 2) {
            let turn = try await backend.next(system: system, messages: messages)
            trace.turns += 1
            trace.inputTokens += turn.inputTokens
            trace.outputTokens += turn.outputTokens
            trace.reportedModel = turn.model
            trace.text = turn.text

            if turn.stopReason == "refusal" {
                trace.error = "refusal: \(turn.refusalCategory ?? "no category given")"
                return
            }
            if turn.stopReason == "max_tokens" {
                // The reply was cut off, so a tool input in it may be incomplete: don't run it.
                trace.error = "max_tokens"
                return
            }
            if turn.toolCalls.isEmpty {
                // Plain text instead of final_answer. Kept as data, not repaired.
                trace.formatError = true
                return
            }

            messages.append(.assistant(turn))
            var results: [ToolResult] = []
            for call in turn.toolCalls {
                let content: String
                if call.name == FinalAnswer.toolName {
                    switch FinalAnswer.parse(call.input) {
                    case .success(let answer):
                        trace.finalAnswer = answer
                        trace.record(call, result: "{}")
                        return
                    case .failure(let error):
                        content = Tool.json(error)
                    }
                } else if let tool = Tool.named(call.name) {
                    if callsLeft > 0 {
                        callsLeft -= 1
                        content = tool.call(call.input, database: database)
                    } else {
                        content = Tool.json(ToolError("No tool calls left.", hint: "Call final_answer now with what you have."))
                    }
                } else {
                    content = Tool.json(ToolError("Unknown tool \"\(call.name)\".",
                                                  hint: "Tools: " + (Tool.all.map(\.name) + [FinalAnswer.toolName]).joined(separator: ", ")))
                }
                let error = trace.record(call, result: content)
                results.append(ToolResult(id: call.id, content: content, isError: error != nil))
            }
            messages.append(.toolResults(results))
        }
        trace.error = "tool_limit"
    }
}

/// Everything that happened while answering one question, for the eval and for debugging.
public struct Trace: Codable, Sendable {
    public var question: String
    /// The model id that was asked for.
    public var model: String
    public var effort: String?
    public var promptVersion: String
    /// The model id the API reported on its last reply.
    public var reportedModel: String?
    public var toolCalls: [ToolCallRecord] = []
    /// How many replies the model gave.
    public var turns = 0
    public var latencySeconds = 0.0
    public var inputTokens = 0
    public var outputTokens = 0
    public var finalAnswer: FinalAnswer?
    /// True when the model answered in plain text instead of calling final_answer.
    public var formatError = false
    /// The plain text of the model's last reply, kept even when it called final_answer.
    public var text = ""
    /// Why there is no answer: a refusal, "max_tokens", "tool_limit", or a network error.
    public var error: String?

    /// Adds one call to the trace and returns the error it hit, if any.
    @discardableResult
    mutating func record(_ call: ToolCall, result: String) -> String? {
        // Every tool, and every rejection in `run`, answers `{"error": ...}` when the call was bad.
        let object = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        let error = object?["error"] as? String
        toolCalls.append(ToolCallRecord(name: call.name, input: String(decoding: call.input, as: UTF8.self),
                                        valid: error == nil, error: error, resultBytes: result.utf8.count, result: result))
        return error
    }
}

/// One tool call as the model made it, and what came back.
public struct ToolCallRecord: Codable, Sendable {
    public var name: String
    /// The inputs exactly as the model wrote them (JSON text).
    public var input: String
    public var valid: Bool
    public var error: String?
    public var resultBytes: Int
    /// The tool's JSON answer: the rows behind the final answer.
    public var result: String
}

/// The structured answer every question must end with, so it can be graded by machine.
/// Field names match the tool's inputs.
public struct FinalAnswer: Codable, Sendable, Equatable {
    public static let toolName = "final_answer"

    public var answer: String
    public var value: Double?
    public var items: [String]?
    public var yes_no: Bool?
    public var confidence: Double?

    /// Checks the model's final_answer input. A bad one goes back to the model as an error
    /// result so it can try again; it is never fixed up here.
    static func parse(_ input: Data) -> Result<FinalAnswer, ToolError> {
        guard let answer = try? JSONDecoder().decode(FinalAnswer.self, from: input) else {
            return .failure(ToolError("Bad final_answer input.", hint: "Send answer, value, items, yes_no and confidence."))
        }
        if let confidence = answer.confidence, !(0...1).contains(confidence) {
            return .failure(ToolError("Bad value for \"confidence\".", hint: "A number from 0 to 1, or null."))
        }
        return .success(answer)
    }

    /// Claude's definition of the tool. Strict mode makes every field present; "null" in a
    /// field's type lets the model leave it empty on purpose.
    public static var claudeSchema: [String: Any] {
        func nullable(_ type: String, _ description: String) -> [String: Any] {
            ["type": [type, "null"], "description": description]
        }
        var items = nullable("array", "The names, when the question asks for a list, or null.")
        items["items"] = ["type": "string"]
        return [
            "name": toolName,
            "description": "Give the final answer to the question. Call this once, last.",
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": [
                    "answer": ["type": "string", "description": "One plain sentence for the person."],
                    "value": nullable("number", "The main number in the answer, in dollars or a count, or null."),
                    "items": items,
                    "yes_no": nullable("boolean", "true or false for a yes-or-no question, otherwise null."),
                    "confidence": nullable("number", "How sure you are, from 0 to 1, or null."),
                ] as [String: Any],
                "required": ["answer", "value", "items", "yes_no", "confidence"],
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }
}

/// A failure outside any one tool call, such as an empty database.
struct AssistantError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
