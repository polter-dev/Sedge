import Foundation

/// Claude through Anthropic's Messages API, called directly with `URLSession`: the API is
/// one web address that takes and returns JSON, so no extra library is needed.
public struct ClaudeBackend: ModelBackend {
    /// The reference model for the project's results. Pass "claude-opus-5-5" as `model`
    /// for the optional second cloud column.
    public static let defaultModel = "claude-sonnet-5-5"

    public let model: String
    public let effort: String?
    private let apiKey: String

    /// `effort` is set explicitly (instead of left to each model's own default) so every run
    /// uses the same level. There is deliberately no `temperature`: these models reject it.
    public init(model: String = defaultModel, effort: String = "medium", apiKey: String) {
        self.model = model
        self.effort = effort
        self.apiKey = apiKey
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
            "tools": Tool.all.map(\.claudeSchema) + [FinalAnswer.claudeSchema],
            "messages": try messages.map(Self.message),
        ]
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
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
