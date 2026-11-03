import Foundation
import Synchronization
import Testing
@testable import SedgeCore

// The Jev client against a fake transport: no test here touches the network or a real key.

let fakeKey = "test-key"

/// A reply in the documented shape (docs.typesafe.ai quick start), with this client's question ids.
let documentedReply = #"""
{
  "model": "jev-1.13.0",
  "answers": {
    "tool": {"type": "choice", "choice": "total_spent", "confidence": 0.42,
             "probabilities": {"total_spent": 0.61, "ask_user": 0.35, "none": 0.04}},
    "needs_clarification": {"type": "noul", "noul": 0.12},
    "in_scope": {"type": "noul", "noul": 0.99},
    "difficulty": {"type": "score", "score": 0.67, "confidence": 0.5,
                   "legend": {"0": "One lookup answers it", "1": "Two lookups or a calculation", "2": "Several steps or a what-if projection"},
                   "probabilities": {"0": 0.33, "1": 0.67, "2": 0.0}}
  },
  "usage": {"input_tokens": 428, "output_tokens": 73}
}
"""#

/// A transport that remembers the request it was given and answers with `status` and `body`,
/// or throws `error` when one is set.
final class FakeJev: Sendable {
    let sent = Mutex<URLRequest?>(nil)
    let status: Int, body: String, error: (any Error & Sendable)?
    init(status: Int = 200, body: String = documentedReply, error: (any Error & Sendable)? = nil) {
        (self.status, self.body, self.error) = (status, body, error)
    }
    var client: JevClient {
        JevClient(apiKey: fakeKey) { request in
            self.sent.withLock { $0 = request }
            if let error = self.error { throw error }
            return (Data(self.body.utf8), HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!)
        }
    }
    /// The JSON body of the last request, parsed back into a dictionary.
    func sentBody() throws -> [String: Any] {
        let data = try #require(sent.withLock { $0?.httpBody })
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Test func requestHoldsOnlyTheQuestionAndEveryToolOption() async throws {
    let fake = FakeJev()
    _ = try await fake.client.decide(question: "How much did I spend on groceries in May?")
    let request = try #require(fake.sent.withLock { $0 })
    #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeKey)")

    let body = try fake.sentBody()
    #expect(Set(body.keys) == ["state", "model", "questions"])
    #expect(body["state"] as? String == "How much did I spend on groceries in May?")
    #expect(body["model"] as? String == "jev-latest")

    let questions = try #require(body["questions"] as? [String: [String: Any]])
    #expect(Set(questions.keys) == ["tool", "needs_clarification", "in_scope", "difficulty"])
    let tool = try #require(questions["tool"])
    #expect(tool["type"] as? String == "choice")
    #expect(tool["instructions"] as? String == JevWording.tool)
    let criteria = try #require(tool["criteria"] as? [String: String])
    #expect(Set(criteria.keys) == Set(Tool.all.map(\.name) + ["ask_user", "none"]))
    for each in Tool.all { #expect(criteria[each.name] == each.description) }
    #expect(criteria["ask_user"] == AskUser.claudeSchema["description"] as? String)
    #expect(criteria["none"] == JevWording.noTool)

    #expect(questions["needs_clarification"]?["type"] as? String == "noul")
    #expect(questions["in_scope"]?["type"] as? String == "noul")
    #expect(questions["difficulty"]?["type"] as? String == "score")
    #expect(questions["difficulty"]?["criteria"] as? [String] == JevWording.difficultyLevels)
}

@Test func previousQuestionIsPrefixedInState() async throws {
    let fake = FakeJev()
    _ = try await fake.client.decide(question: "And in June?", previousQuestion: "How much did I spend on groceries in May?")
    #expect(try fake.sentBody()["state"] as? String == "Previous question: How much did I spend on groceries in May?\nQuestion: And in June?")
}

@Test func documentedReplyDecodesIntoDecision() async throws {
    let decision = try await FakeJev().client.decide(question: "How much did I spend on groceries in May?")
    #expect(decision == JevDecision(model: "jev-1.13.0", tool: "total_spent", toolConfidence: 0.42,
                                    toolProbabilities: ["total_spent": 0.61, "ask_user": 0.35, "none": 0.04],
                                    needsClarification: 0.12, inScope: 0.99, difficulty: 0.67, difficultyConfidence: 0.5,
                                    inputTokens: 428, outputTokens: 73))
    // Codable both ways, so a trace can store it and read it back unchanged.
    #expect(try JSONDecoder().decode(JevDecision.self, from: JSONEncoder().encode(decision)) == decision)
}

@Test func nonSuccessReplyThrows() async throws {
    let fake = FakeJev(status: 401, body: #"{"error": "invalid key"}"#)
    await #expect(throws: JevError.http(status: 401, body: #"{"error": "invalid key"}"#)) {
        try await fake.client.decide(question: "Hi")
    }
}

@Test func malformedBodyThrows() async throws {
    let fake = FakeJev(body: #"{"model": "jev-1.13.0", "answers": {}}"#)
    let error = await #expect(throws: JevError.self) { try await fake.client.decide(question: "Hi") }
    guard case .malformedBody = error else { Issue.record("Expected malformedBody, got \(String(describing: error))"); return }
}

@Test func timeoutThrows() async throws {
    let fake = FakeJev(error: URLError(.timedOut))
    await #expect(throws: JevError.timeout) { try await fake.client.decide(question: "Hi") }
}
