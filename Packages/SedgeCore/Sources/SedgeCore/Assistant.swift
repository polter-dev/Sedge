import Foundation
import Jinja

/// One model turn. It is shown the chat so far (`Assistant.messages`) and the tool definitions,
/// and returns the raw text it wrote, stopped once one tool call is complete. The on-device model
/// (`QwenModel`) and the scripted fake (`ScriptedModel`) both answer through this.
public protocol AssistantModel: Sendable {
    func reply(to messages: [Value], tools: [Value]) async throws -> String
}

/// A model turn that can't go on, as the benchmark notebook names them.
public enum ModelCrash: Error, Equatable {
    /// The chat no longer fits in the model's context.
    case context
    /// The model wrote its whole output allowance without finishing a tool call.
    case maxTokens
}

/// The question-answering loop, ported from the benchmark notebook (`benchmarks/benchmark.ipynb`,
/// the Qwen row with Jev off): the same system prompt, tools, step limit, compaction, repair turn
/// and `final_answer` check, so the app answers the way the measured model did.
public enum Assistant {
    /// The notebook's `SYSTEM_PROMPT`, copied verbatim. `{today}` becomes the dataset's `as_of`.
    public static let systemPrompt = """
        You answer questions about one person's own bank data. Today is {today}. Every relative date, like "last month" or "this year", counts back from today. People say "last month" loosely, so take it to mean the last 45 days, up to today.

        You cannot see the data yourself. Use the tools to look it up. Each step, call one tool or finish. You have at most 8 steps, so call the tool that answers the question most directly.

        Never do arithmetic yourself. Every number and date you report must appear exactly as a tool returned it.

        End every question by calling final_answer with:
        answer_type: number, list, yes_no, text, or declined.
        value: a dollar amount like $1,234.56, a date as YYYY-MM-DD, a list of names, yes or no, or one short text.
        note: one plain sentence for the person.

        Use declined when the question is not about this person's bank data or the tools cannot answer it. Do not guess.

        If a tool returns an error, read its hint, fix the input and call the tool again.

        Call ask_user only when the answer would change depending on what the person means, and at most once. If they do not answer, take the most likely meaning and say so in the note.

        Keep the note short, in plain words, and do not mention the tools.
        """

    /// The one message a model gets after ending in plain text, sent as the person's turn.
    public static let repairMessage = "Please give that answer by calling final_answer."

    /// Model turns per question (the notebook's `STEP_LIMIT`).
    public static let stepLimit = 8

    public static let answerTypes = ["number", "list", "yes_no", "text", "declined"]

    /// The inputs of the notebook's `final_answer` tool, with keys in the notebook's order (the order is part of the prompt).
    static let finalAnswerSchema: Value = .object([
            "type": .string("object"),
            "properties": .object([
                "answer_type": .object(["type": .string("string"), "enum": .array(answerTypes.map(Value.string)),
                                        "description": .string("What kind of answer this is.")]),
                "value": .object(["type": .string("string"),
                                  "description": .string("A dollar amount like $1,234.56, a date as YYYY-MM-DD, "
                                      + "names separated by commas, yes or no, or one short text. Empty when declined.")]),
                "note": .object(["type": .string("string"), "description": .string("One plain sentence for the person.")]),
            ]),
            "required": .array(["answer_type", "value", "note"].map(Value.string)),
            "additionalProperties": .boolean(false),
    ])

    /// Every tool the model is offered, as the chat template wants them: Sedge's tools, `ask_user`
    /// and `final_answer`, without `strict` (the Qwen rows never send it). Sedge's own schemas come
    /// out with sorted keys, as the notebook's helper sends them.
    public static let tools: [Value] = (Tool.all.map(\.claudeSchema) + [AskUser.claudeSchema]).map { schema in
        function(name: schema["name"] as! String, description: schema["description"] as! String,
                 parameters: try! Value(any: schema["input_schema"]))
    } + [function(name: "final_answer", description: "Finish the question with the answer for the person.",
                  parameters: finalAnswerSchema)]

    private static func function(name: String, description: String, parameters: Value) -> Value {
        .object(["type": .string("function"),
                 "function": .object(["name": .string(name), "description": .string(description), "parameters": parameters])])
    }

    /// The answer `final_answer` carried.
    public struct FinalAnswer: Equatable, Sendable {
        public var answerType: String
        public var value: String
        public var note: String
    }

    /// How a question ended.
    public enum Outcome: Equatable, Sendable {
        case answer(FinalAnswer)
        /// Eight steps went by without a valid `final_answer`.
        case stepLimit
        /// The chat overflowed the model's context a second time, after compaction.
        case contextFull
        /// A reply that can't be read ("malformed") or one cut off at the output cap ("max_tokens").
        case crashed(String)
    }

    /// One step the model is shown again: a tool call and its result, or a plain-text ending.
    struct Step {
        var name: String?
        var input: OrderedDictionary<String, Value> = [:]
        var result = ""
        var text = ""
    }

    /// Answers one question on `database`, as the notebook's `run_question` does. Each question
    /// starts fresh: earlier turns of the chat are not shown to the model, as in the benchmark.
    public static func run(_ question: String, database: SedgeDatabase, model: any AssistantModel,
                           askPerson: AskPerson?) async -> Outcome {
        let today = (try? database.asOf()) ?? ""
        let system = systemPrompt.replacingOccurrences(of: "{today}", with: today)
        var history: [Step] = []
        var steps = 0
        var repaired = false
        var compacted = false
        // A pending repair (the last step is plain text) gets its turn even past the step limit.
        while steps < stepLimit || history.last.map({ $0.name == nil }) == true {
            let text: String
            do {
                text = try await model.reply(to: messages(system: system, question: question, history: history), tools: tools)
            } catch ModelCrash.context {
                // Compacted once: start again from the question and only the latest step. Steps used still count.
                if compacted { return .contextFull }
                compacted = true
                history = Array(history.suffix(1))
                continue
            } catch ModelCrash.maxTokens {
                return .crashed("max_tokens")
            } catch {
                return .crashed("\(error)")
            }
            steps += 1
            let call: (String, OrderedDictionary<String, Value>)?
            do { call = try parseCall(text) } catch { return .crashed("malformed") }
            guard let (name, input) = call else {
                // Plain text instead of a tool call: one repair turn, then it is a malformed reply.
                if repaired { return .crashed("malformed") }
                repaired = true
                history.append(Step(name: nil, text: text))
                continue
            }
            let result = name == "final_answer" ? checkFinalAnswer(input) : await runTool(name, input, database, askPerson)
            history.append(Step(name: name, input: input, result: result))
            if name == "final_answer", let answer = answer(from: input) { return .answer(answer) }
        }
        return .stepLimit
    }

    /// The chat as the model sees it, built the way the notebook's `mlx_turn` builds it.
    static func messages(system: String, question: String, history: [Step]) -> [Value] {
        var messages: [Value] = [.object(["role": .string("system"), "content": .string(system)]),
                                 .object(["role": .string("user"), "content": .string(question)])]
        for step in history {
            guard let name = step.name else {
                messages += [.object(["role": .string("assistant"), "content": .string(step.text)]),
                             .object(["role": .string("user"), "content": .string(repairMessage)])]
                continue
            }
            let call: Value = .object(["type": .string("function"),
                                       "function": .object(["name": .string(name), "arguments": .object(step.input.mapKeys)])])
            messages += [.object(["role": .string("assistant"), "content": .string(""), "tool_calls": .array([call])]),
                         .object(["role": .string("tool"), "content": .string(step.result)])]
        }
        return messages
    }

    /// The answer when `final_answer`'s input is well formed (the notebook's `check_final_answer`), else nil.
    private static func answer(from input: OrderedDictionary<String, Value>) -> FinalAnswer? {
        guard Set(input.keys) == ["answer_type", "value", "note"],
              case .string(let type) = input["answer_type"], answerTypes.contains(type),
              case .string(let value) = input["value"], case .string(let note) = input["note"]
        else { return nil }
        return FinalAnswer(answerType: type, value: value, note: note)
    }

    /// The result the model reads after `final_answer`, as Python's json.dumps writes it.
    static func checkFinalAnswer(_ input: OrderedDictionary<String, Value>) -> String {
        if answer(from: input) != nil { return #"{"ok": true}"# }
        return #"{"error": "Bad final_answer input.", "hint": "Send answer_type (number, list, yes_no, text or declined), value and note, all as text."}"#
    }

    /// Runs one of Sedge's tools or `ask_user`, as the notebook's helper does, and returns the
    /// result the way the notebook passes it on: parsed, then written again by Python's json.dumps.
    static func runTool(_ name: String, _ input: OrderedDictionary<String, Value>, _ database: SedgeDatabase,
                        _ askPerson: AskPerson?) async -> String {
        let json = (try? JSONSerialization.data(withJSONObject: input.mapKeys.plainDictionary, options: .fragmentsAllowed)) ?? Data("{}".utf8)
        let text: String
        if name == AskUser.toolName {
            text = await AskUser.run(json, database: database, askPerson: askPerson).content
        } else if let tool = Tool.named(name) {
            text = tool.call(json, database: database)
        } else {
            let names = (Tool.all.map(\.name) + [AskUser.toolName]).joined(separator: ", ")
            text = #"{"error":"Unknown tool \"\#(name)\".","hint":"Tools: \#(names)."}"#
        }
        return pythonJSON(text)
    }

    /// Rewrites compact JSON the way Python's `json.dumps(json.loads(text))` writes it: a space
    /// after each `,` and `:`, and every non-ASCII character as `\uXXXX`. The notebook sends tool
    /// results through that round trip, so the model saw them in this form.
    static func pythonJSON(_ compact: String) -> String {
        var out = ""
        var inString = false, escaped = false
        for scalar in compact.unicodeScalars {
            if inString && escaped {
                escaped = false
                out.unicodeScalars.append(scalar)
            } else if inString && scalar == "\\" {
                escaped = true
                out += "\\"
            } else if inString && scalar.value > 0x7F {
                // Characters past U+FFFF become two \u escapes (a surrogate pair), as Python writes them.
                for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
            } else {
                out.unicodeScalars.append(scalar)
                if scalar == "\"" { inString.toggle() } else if !inString && (scalar == "," || scalar == ":") { out += " " }
            }
        }
        return out
    }

    // MARK: - Reading a tool call (mlx_lm's qwen3_coder parser)

    static let callStart = "<tool_call>", callEnd = "</tool_call>"

    /// True once the text holds one whole call, the point where the notebook stops generating.
    public static func isComplete(_ text: String) -> Bool {
        guard let start = text.range(of: callStart) else { return false }
        return text[start.upperBound...].contains(callEnd)
    }

    struct Malformed: Error {}

    /// The call in a model's text, nil for plain text, or `Malformed` when the call can't be read.
    /// A port of mlx_lm's `qwen3_coder.parse_tool_call`, used on the text between the first
    /// `<tool_call>` and the next `</tool_call>`, trimmed.
    static func parseCall(_ text: String) throws -> (String, OrderedDictionary<String, Value>)? {
        guard let start = text.range(of: callStart) else { return nil }
        var body = text[start.upperBound...]
        if let end = body.range(of: callEnd) { body = body[..<end.lowerBound] }
        let call = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // `<function=(.*?)</function>$`: from the first opening to the closing that ends the text.
        guard call.hasSuffix("</function>"), let open = call.range(of: "<function=") else { throw Malformed() }
        let inner = call[open.upperBound..<call.index(call.endIndex, offsetBy: -"</function>".count)]
        guard let (name, rest) = leadingName(inner) else { throw Malformed() }
        let properties = parameters(of: name)
        var arguments: OrderedDictionary<String, Value> = [:]
        var remaining = rest
        // `<parameter=(.*?)</parameter>`: each opening up to the next closing.
        while let open = remaining.range(of: "<parameter="), let close = remaining[open.upperBound...].range(of: "</parameter>") {
            let match = remaining[open.upperBound..<close.lowerBound]
            remaining = remaining[close.upperBound...]
            guard let (key, raw) = leadingName(match) else { continue }
            var value = raw
            if value.hasPrefix("\n") { value = value.dropFirst() }
            if value.hasSuffix("\n") { value = value.dropLast() }
            arguments[key] = try convert(String(value), schema: properties[key])
        }
        return (name, arguments)
    }

    /// `\s*([^\s<>]+)>?` at the start of `text`: a name and what follows it, or nil.
    private static func leadingName(_ text: Substring) -> (String, Substring)? {
        let trimmed = text.drop { $0.isWhitespace }
        let name = trimmed.prefix { !$0.isWhitespace && $0 != "<" && $0 != ">" }
        guard !name.isEmpty else { return nil }
        var rest = trimmed[name.endIndex...]
        if rest.hasPrefix(">") { rest = rest.dropFirst() }
        return (String(name), rest)
    }

    /// The `properties` of a tool's parameters, by input name.
    private static func parameters(of name: String) -> OrderedDictionary<ObjectKey, Value> {
        for case .object(let tool) in tools {
            guard case .object(let function) = tool["function"], function["name"] == .string(name),
                  case .object(let parameters) = function["parameters"], case .object(let properties) = parameters["properties"]
            else { continue }
            return properties
        }
        return [:]
    }

    /// A parameter's text turned into the type its schema names, as `_convert_param_value` does.
    private static func convert(_ text: String, schema: Value?) throws -> Value {
        if text.lowercased() == "null" { return .null }
        guard case .object(let schema) = schema else { return .string(text) }
        guard case .string(let rawType) = schema["type"] else {
            let json = try? Value(any: JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed))
            if case .array = json { return json! }
            if case .object = json { return json! }
            return .string(text)
        }
        let type = rawType.trimmingCharacters(in: .whitespaces).lowercased()
        // Python's float() allows spaces around the number and rejects inf and nan here (int() of them fails).
        let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite ? $0 : nil }
        if ["string", "str", "text", "varchar", "char", "enum"].contains(type) { return .string(text) }
        if ["int", "uint", "long", "short", "unsigned"].contains(where: type.hasPrefix) {
            guard let number, number == number.rounded(.towardZero), abs(number) < 1e18 else { throw Malformed() }
            return .int(Int(number))
        }
        if type.hasPrefix("num") || type.hasPrefix("float") {
            guard let number else { throw Malformed() }
            return number == number.rounded(.towardZero) && abs(number) < 1e18 ? .int(Int(number)) : .double(number)
        }
        if ["boolean", "bool", "binary"].contains(type) { return .boolean(text.lowercased() == "true") }
        if ["object", "array", "arr"].contains(type) || type.hasPrefix("dict") || type.hasPrefix("list"),
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed),
           let value = try? Value(any: object) {
            return value
        }
        // shortcut: Python then tries ast.literal_eval (e.g. a single-quoted list); that is left as text here.
        // Revisit if traces show the model writing Python literals.
        return .string(text)
    }
}

extension OrderedDictionary where Key == String, Value == Jinja.Value {
    /// The same entries keyed the way Jinja objects are.
    var mapKeys: OrderedDictionary<ObjectKey, Jinja.Value> {
        OrderedDictionary<ObjectKey, Jinja.Value>(uniqueKeysWithValues: map { (.string($0.key), $0.value) })
    }
}

extension OrderedDictionary where Key == ObjectKey, Value == Jinja.Value {
    /// Keyed by plain strings with Foundation values, for JSONSerialization.
    var plainDictionary: [String: Any] {
        Dictionary(uniqueKeysWithValues: map { ($0.key.stringValue, $0.value.plain) })
    }
}

extension Value {
    /// The value as Foundation's JSON types, so a tool reads the input the notebook's helper got.
    var plain: Any {
        switch self {
        case .string(let text): text
        case .int(let number): number
        case .double(let number): number
        case .boolean(let flag): flag
        case .array(let items): items.map(\.plain)
        case .object(let object): object.plainDictionary
        default: NSNull()
        }
    }
}

/// A stand-in for the model that gives scripted replies, one per turn, in order: raw text the way
/// Qwen writes it (see `call`), or a crash. Past the end of the script it answers in plain text.
/// Tests use it, and so does the iOS Simulator, where MLX can't run.
public actor ScriptedModel: AssistantModel {
    private var replies: [Result<String, ModelCrash>]
    private let delay: Duration
    /// The chat each turn was shown, so tests can check what the model saw.
    public private(set) var seen: [[Value]] = []

    public init(_ replies: [Result<String, ModelCrash>], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    public func reply(to messages: [Value], tools: [Value]) async throws -> String {
        seen.append(messages)
        try? await Task.sleep(for: delay)
        return replies.isEmpty ? "No more script." : try replies.removeFirst().get()
    }

    /// One tool call in Qwen's format, e.g. `call("account_balances")`.
    public static func call(_ name: String, _ arguments: KeyValuePairs<String, String> = [:]) -> Result<String, ModelCrash> {
        let parameters = arguments.map { "<parameter=\($0.key)>\n\($0.value)\n</parameter>\n" }.joined()
        return .success("<tool_call>\n<function=\(name)>\n\(parameters)</function>\n</tool_call>")
    }
}
