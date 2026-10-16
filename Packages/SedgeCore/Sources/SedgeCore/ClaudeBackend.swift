import Foundation

/// Claude through Anthropic's Messages API, called directly with `URLSession`: the API is
/// one web address that takes and returns JSON, so no extra library is needed.
public struct ClaudeBackend: ModelBackend {
    /// The reference model for the project's results. Pass "claude-opus-5-5" as `model`
    /// for the optional second cloud column.
    public static let defaultModel = "claude-sonnet-5-5"

    public let model: String
    public let effort: String?
    /// False for the context-stuffing baseline, which offers only final_answer.
    public let dataTools: Bool
    private let apiKey: String

    /// `effort` is set explicitly (instead of left to each model's own default) so every run
    /// uses the same level. There is deliberately no `temperature`: these models reject it.
    public init(model: String = defaultModel, effort: String = "medium", apiKey: String, dataTools: Bool = true) {
        self.model = model
        self.effort = effort
        self.apiKey = apiKey
        self.dataTools = dataTools
    }

    /// The tool definitions sent with every request. The eval runner hashes the same list.
    /// The context baseline gets neither the data tools nor ask_user, so it stays as it was.
    public static func tools(dataTools: Bool) -> [[String: Any]] {
        (dataTools ? Tool.all.map(\.claudeSchema) + [AskUser.claudeSchema] : []) + [FinalAnswer.claudeSchema]
    }

    /// The API key from the `ANTHROPIC_API_KEY` environment variable (command line), or from
    /// the app's Info.plist, which Xcode fills in from `Secrets.xcconfig`. Nil when neither is set.
    public static func apiKey() -> String? {
        let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            ?? Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_API_KEY") as? String
        return key?.isEmpty == false ? key : nil
    }

    public func next(system: String, messages: [ModelMessage]) async throws -> ModelTurn {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        // A reply with thinking can take a while; the default 60 seconds is too tight.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try body(system: system, messages: messages)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // The API explains a failure in error.message. The key is never part of it.
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (object?["error"] as? [String: Any])?["message"] as? String
            throw AssistantError("Claude API error \(status): \(message ?? String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return try Self.parse(data)
    }

    /// The request's JSON body.
    func body(system: String, messages: [ModelMessage]) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            // Adaptive thinking is these models' default; it is spelled out so a change in
            // defaults can't quietly change results.
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": effort ?? "medium"],
            // "auto" is the only choice: these models reject forcing a tool, so the prompt
            // asks for final_answer instead.
            "tool_choice": ["type": "auto"],
            "messages": try messages.map(Self.message),
        ]
        // The tools are added as text because JSONSerialization can't keep their inputs' order.
        let tools = try "[" + Self.tools(dataTools: dataTools).map(Self.json(tool:)).joined(separator: ",") + "]"
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys).dropLast() + Data((",\"tools\":" + tools + "}").utf8)
    }

    /// One tool definition as JSON text. In strict mode the model has to write a tool's inputs
    /// in the order its schema lists them, and can't go back for one it skipped. With sorted
    /// keys, total_spent listed end_date, merchant, start_date: the model wrote both dates and
    /// had no way left to name the store. So the required inputs come first, then the optional
    /// ones in the order the tool declares them. Every other key stays sorted.
    static func json(tool schema: [String: Any]) throws -> String {
        let required = (schema["input_schema"] as? [String: Any])?["required"] as? [String] ?? []
        let declared = Tool.named(schema["name"] as? String ?? "")?.inputs.map(\.name) ?? []
        return try json(schema, propertyOrder: required + declared.filter { !required.contains($0) })
    }

    /// JSON text with sorted keys, except that a "properties" object's keys follow `propertyOrder`.
    private static func json(_ value: Any, propertyOrder: [String], isProperties: Bool = false) throws -> String {
        if let object = value as? [String: Any] {
            let order = isProperties ? propertyOrder : []
            // Keys missing from `order` (all of them, outside "properties") go last, sorted.
            let rank = { (key: String) in (order.firstIndex(of: key) ?? order.count, key) }
            return try "{" + object.keys.sorted { rank($0) < rank($1) }.map { key in
                try json(key, propertyOrder: []) + ":" + json(object[key]!, propertyOrder: propertyOrder, isProperties: key == "properties")
            }.joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            return try "[" + array.map { try json($0, propertyOrder: propertyOrder) }.joined(separator: ",") + "]"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self)
    }

    /// One conversation entry in the Messages API's shape.
    static func message(_ message: ModelMessage) throws -> [String: Any] {
        switch message {
        case .user(let text):
            return ["role": "user", "content": text]
        case .assistant(let turn):
            return ["role": "assistant", "content": try JSONSerialization.jsonObject(with: turn.raw)]
        case .toolResults(let results):
            // All results for one reply go back together, in one user message.
            return ["role": "user", "content": results.map { result in
                ["type": "tool_result", "tool_use_id": result.id, "content": result.content, "is_error": result.isError] as [String: Any]
            }]
        }
    }

    /// Reads one reply. Its content blocks are kept whole in `raw`, including the thinking
    /// blocks this code ignores, because the next request has to send them back unchanged.
    static func parse(_ data: Data) throws -> ModelTurn {
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = reply["content"] as? [[String: Any]] else {
            throw AssistantError("Claude sent a reply without content.")
        }
        let blocks = { (type: String) in content.filter { $0["type"] as? String == type } }
        let calls = try blocks("tool_use").map { block in
            ToolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                     input: try JSONSerialization.data(withJSONObject: block["input"] ?? [:], options: .sortedKeys))
        }
        let usage = reply["usage"] as? [String: Any]
        return ModelTurn(
            text: blocks("text").compactMap { $0["text"] as? String }.joined(separator: "\n"),
            toolCalls: calls,
            stopReason: reply["stop_reason"] as? String ?? "",
            // Only filled on a refusal, and even then it may be missing.
            refusalCategory: (reply["stop_details"] as? [String: Any])?["category"] as? String,
            model: reply["model"] as? String ?? "",
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0,
            raw: try JSONSerialization.data(withJSONObject: content))
    }
}
