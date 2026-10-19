//
//  ScriptedModel.swift
//  Sedge
//

#if DEBUG
import Foundation
import SedgeCore

/// A pretend model for UI tests, so they run with no network and no paid model calls.
/// Launch with `-scriptedModel YES`. Every question asks one quick question, then answers
/// with whatever came back, so a test can see which saved answer was used.
/// Debug builds only: a released app must never answer with made-up text.
struct ScriptedModel: ModelBackend {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "scriptedModel") }

    let model = "scripted"
    let effort: String? = nil

    func next(system: String, messages: [ModelMessage]) async throws -> ModelTurn {
        // After ask_user replied, answer with its reply; otherwise ask first.
        if case .toolResults(let results)? = messages.last {
            struct Reply: Decodable { let answer: String? }
            let reply = results.first.flatMap { try? JSONDecoder().decode(Reply.self, from: Data($0.content.utf8)) }?.answer
            let answer: [String: Any?] = ["answer": "Groceries count as food: \(reply ?? "not answered").",
                                          "value": nil, "items": nil, "yes_no": nil, "confidence": nil]
            return turn("final_answer", answer)
        }
        return turn("ask_user", ["question": "Should food include groceries?",
                                 "options": ["Yes, groceries too", "No, eating out only"],
                                 "fact_key": "food_includes_groceries"])
    }

    /// One reply that calls `tool` with `input`.
    private func turn(_ tool: String, _ input: [String: Any?]) -> ModelTurn {
        // JSONSerialization writes nil as null only when it is NSNull.
        let json = try! JSONSerialization.data(withJSONObject: input.mapValues { $0 ?? NSNull() })
        return ModelTurn(text: "", toolCalls: [ToolCall(id: "scripted", name: tool, input: json)], stopReason: "tool_use",
                         model: model, inputTokens: 0, outputTokens: 0, raw: Data("[]".utf8))
    }
}
#endif
