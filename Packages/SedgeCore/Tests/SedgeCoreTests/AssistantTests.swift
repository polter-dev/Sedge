import Foundation
import Testing
@testable import SedgeCore

// The loop tested with a scripted model that replays fixed replies, so no network is used.

/// A pretend model that gives the scripted replies in order and remembers what it was sent.
actor ScriptedBackend: ModelBackend {
    nonisolated let model = "scripted"
    nonisolated let effort: String? = nil
    private var replies: [ModelTurn]
    private(set) var received: [[ModelMessage]] = []
    private(set) var systems: [String] = []

    init(_ replies: [ModelTurn]) { self.replies = replies }

    func next(system: String, messages: [ModelMessage]) async throws -> ModelTurn {
        received.append(messages)
        systems.append(system)
        return replies.removeFirst()
    }
}

/// A reply that calls tools, given as (name, JSON input) pairs.
func calling(_ calls: [(String, String)], stop: String = "tool_use") -> ModelTurn {
    ModelTurn(text: "", toolCalls: calls.enumerated().map { ToolCall(id: "call\($0.offset)", name: $0.element.0, input: Data($0.element.1.utf8)) },
              stopReason: stop, model: "scripted", inputTokens: 10, outputTokens: 5, raw: Data("[]".utf8))
}

let netflix = #"{"merchant": "Netflix", "start_date": "2026-01-01", "end_date": "2026-06-30"}"#
let answer100 = #"{"answer": "You spent $100.44.", "value": 100.44, "items": null, "yes_no": null, "confidence": 0.9}"#

@Test func brokenToolInputGetsAnErrorAndARetry() async throws {
    // February 30 doesn't exist, so the first call is rejected; the model then fixes the date.
    let broken = #"{"merchant": "Netflix", "start_date": "2026-01-01", "end_date": "2026-02-30"}"#
    let backend = ScriptedBackend([calling([("total_spent", broken)]), calling([("total_spent", netflix)]),
                                   calling([("final_answer", answer100)])])
    let trace = await Assistant(backend: backend, database: try organizedPersona("maya")).ask("Netflix, Jan to Jun?")

    #expect(trace.error == nil)
    #expect(trace.toolCalls.map(\.valid) == [false, true, true])
    #expect(trace.toolCalls[0].error == "Bad value for \"end_date\".")
    #expect(trace.finalAnswer?.value == 100.44)
    #expect(trace.turns == 3)
    #expect(trace.inputTokens == 30 && trace.outputTokens == 15)

    // The model was shown the error as a tool result, marked as an error.
    guard case .toolResults(let results) = await backend.received[1].last else { Issue.record("no tool results"); return }
    #expect(results.count == 1 && results[0].isError && results[0].content.contains("Bad value"))
}

@Test func unknownToolAndBadFinalAnswerGoBackAsErrors() async throws {
    let badAnswer = #"{"answer": "?", "value": null, "items": null, "yes_no": null, "confidence": 3}"#
    let backend = ScriptedBackend([calling([("spend_total", "{}"), ("final_answer", badAnswer)]), calling([("final_answer", answer100)])])
    let trace = await Assistant(backend: backend, database: try organizedPersona("maya")).ask("?")
    #expect(trace.toolCalls.map(\.valid) == [false, false, true])
    #expect(trace.toolCalls[0].error == "Unknown tool \"spend_total\".")
    #expect(trace.toolCalls[1].error == "Bad value for \"confidence\".")
    #expect(trace.finalAnswer?.value == 100.44)
}

@Test func plainTextIsAFormatErrorAndTheTextIsKept() async throws {
    var reply = calling([], stop: "end_turn")
    reply.text = "You spent $100.44 at Netflix."
    let trace = await Assistant(backend: ScriptedBackend([reply]), database: try organizedPersona("maya")).ask("?")
    #expect(trace.formatError)
    #expect(trace.finalAnswer == nil)
    #expect(trace.text == "You spent $100.44 at Netflix.")
}

@Test func refusalIsALabeledError() async throws {
    var reply = calling([], stop: "refusal")
    reply.refusalCategory = "cyber"
    let trace = await Assistant(backend: ScriptedBackend([reply]), database: try organizedPersona("maya")).ask("?")
    #expect(trace.error == "refusal: cyber")
    #expect(!trace.formatError)
}

@Test func callsPastTheLimitAreRefused() async throws {
    // A model that never stops calling tools: 8 replies, each with one call.
    let backend = ScriptedBackend(Array(repeating: calling([("total_spent", netflix)]), count: Assistant.maxToolCalls + 2))
    let trace = await Assistant(backend: backend, database: try organizedPersona("maya")).ask("?")
    #expect(trace.error == "tool_limit")
    #expect(trace.toolCalls.filter(\.valid).count == Assistant.maxToolCalls)
    #expect(trace.toolCalls.last?.error == "No tool calls left.")
}

// MARK: - Claude's request and reply format

@Test func claudeRequestSetsEffortAndStrictToolsAndNoTemperature() throws {
    let backend = ClaudeBackend(apiKey: "test")
    let turn = calling([("total_spent", netflix)])
    let data = try backend.body(system: "S", messages: [.user("Q"), .assistant(turn),
                                                         .toolResults([ToolResult(id: "call0", content: "{}", isError: true)])])
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["model"] as? String == "claude-sonnet-5-5")
    #expect(body["temperature"] == nil)
    #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
    #expect((body["tool_choice"] as? [String: Any])?["type"] as? String == "auto")
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.map { $0["name"] as! String } == Tool.all.map(\.name) + ["ask_user", "final_answer"])
    #expect(tools.allSatisfy { $0["strict"] as? Bool == true })
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.map { $0["role"] as! String } == ["user", "assistant", "user"])
    let result = try #require((messages[2]["content"] as? [[String: Any]])?.first)
    #expect(result["tool_use_id"] as? String == "call0" && result["is_error"] as? Bool == true)
}

/// Strict mode makes the model write inputs in the order the schema lists them. Sorted keys
/// put end_date before merchant, and the model kept leaving the store out of total_spent.
@Test func claudeRequestListsRequiredInputsFirstThenDeclaredOrder() throws {
    let body = String(decoding: try ClaudeBackend(apiKey: "test").body(system: "", messages: [.user("?")]), as: UTF8.self)
    for schema in ClaudeBackend.tools(dataTools: true) {
        let text = try ClaudeBackend.json(tool: schema)
        #expect(body.contains(text))
        let input = try #require(schema["input_schema"] as? [String: Any])
        let required = try #require(input["required"] as? [String])
        let declared = Tool.named(schema["name"] as! String)?.inputs.map(\.name) ?? required
        // Each property's position in the text, read in order.
        let written = try #require(input["properties"] as? [String: Any]).keys
            .sorted { text.range(of: "\"\($0)\":{")!.lowerBound < text.range(of: "\"\($1)\":{")!.lowerBound }
        #expect(written == required + declared.filter { !required.contains($0) }, "\(schema["name"]!)")
    }
    #expect(body.contains(#""properties":{"start_date":"#) && body.contains(#""required":["start_date","end_date"]"#))
    #expect(try JSONSerialization.jsonObject(with: Data(body.utf8)) is [String: Any])
}

@Test func claudeReplyIsParsedAndKeptWhole() throws {
    let reply = #"""
    {"model": "claude-sonnet-5-5", "stop_reason": "tool_use", "stop_details": null,
     "usage": {"input_tokens": 1200, "output_tokens": 80},
     "content": [{"type": "thinking", "thinking": "", "signature": "abc"},
                 {"type": "text", "text": "Checking."},
                 {"type": "tool_use", "id": "toolu_1", "name": "total_spent", "input": {"merchant": "Netflix"}}]}
    """#
    let turn = try ClaudeBackend.parse(Data(reply.utf8))
    #expect(turn.text == "Checking.")
    #expect(turn.toolCalls.map(\.name) == ["total_spent"])
    #expect(String(decoding: turn.toolCalls[0].input, as: UTF8.self) == #"{"merchant":"Netflix"}"#)
    #expect(turn.inputTokens == 1200 && turn.outputTokens == 80 && turn.model == "claude-sonnet-5-5")
    // The thinking block is still there, to be sent back unchanged.
    let raw = try #require(JSONSerialization.jsonObject(with: turn.raw) as? [[String: Any]])
    #expect(raw.first?["signature"] as? String == "abc")

    let refusal = #"{"model": "m", "stop_reason": "refusal", "stop_details": {"type": "refusal", "category": "bio"}, "content": []}"#
    let refused = try ClaudeBackend.parse(Data(refusal.utf8))
    #expect(refused.stopReason == "refusal" && refused.refusalCategory == "bio")
}
