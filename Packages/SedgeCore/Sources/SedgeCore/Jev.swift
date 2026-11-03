import Foundation

/// Every piece of wording sent to Jev, kept in one place so it is easy to change.
/// Tool names and descriptions come from `Tool.all` and `AskUser`, so they never drift.
enum JevWording {
    static let tool = "Which tool should be called first to answer the question?"
    static let noTool = "No lookup can answer this: it is outside the person's bank data or needs no data."
    static let needsClarification = "The question is ambiguous and the person must clarify it before it can be answered."
    static let inScope = "The question is about the person's own bank accounts, spending, income, bills, balances or savings."
    static let difficulty = "How much work answering the question takes."
    static let difficultyLevels = ["One lookup answers it", "Two lookups or a calculation", "Several steps or a what-if projection"]
}

/// Jev's answers for one question, flattened so a trace can record it as is.
public struct JevDecision: Codable, Sendable, Equatable {
    /// The Jev version that ran, e.g. "jev-1.13.0".
    public let model: String
    /// The tool Jev picks first: a name from `Tool.all`, "ask_user" or "none".
    public let tool: String
    public let toolConfidence: Double
    public let toolProbabilities: [String: Double]
    /// Probability (0 to 1) that the question must be clarified first.
    public let needsClarification: Double
    /// Probability (0 to 1) that the question is about the person's own bank data.
    public let inScope: Double
    /// Position on the difficulty levels, from 0 (one lookup) to 2 (several steps); can fall between two levels.
    public let difficulty: Double
    public let difficultyConfidence: Double
    public let inputTokens: Int
    public let outputTokens: Int
}

/// Why a Jev call failed. There is no fallback here: what to do next is the caller's choice.
public enum JevError: Error, Equatable, CustomStringConvertible {
    case http(status: Int, body: String)
    case timeout
    case network(String)
    case malformedBody(String)

    public var description: String {
        switch self {
        case let .http(status, body): "Jev replied with HTTP \(status): \(body)"
        case .timeout: "Jev did not reply within \(Int(JevClient.timeout)) seconds."
        case let .network(cause): "Could not reach Jev: \(cause)"
        case let .malformedBody(cause): "Jev's reply could not be read: \(cause)"
        }
    }
}

/// Asks TypeSafe's Jev classifier which tool a question needs. Only the question text is
/// sent: never transactions, balances, tool results or profile facts.
public struct JevClient: Sendable {
    /// Sends one HTTP request. Tests pass a fake so they never touch the network.
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    /// shortcut: a fixed timeout, revisit once real call times are measured.
    static let timeout: TimeInterval = 10

    let apiKey: String
    let send: Send

    /// `apiKey` comes from the caller: the client never reads files or the environment.
    public init(apiKey: String, send: @escaping Send = { try await URLSession.shared.data(for: $0) }) {
        self.apiKey = apiKey
        self.send = send
    }

    public func decide(question: String, previousQuestion: String? = nil) async throws -> JevDecision {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(question: question, previousQuestion: previousQuestion),
                                                      options: .sortedKeys)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw JevError.timeout
        } catch {
            throw JevError.network(error.localizedDescription)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw JevError.malformedBody("not an HTTP reply") }
        guard (200..<300).contains(status) else { throw JevError.http(status: status, body: String(decoding: data, as: UTF8.self)) }

        let reply: Reply
        do {
            reply = try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw JevError.malformedBody(String(describing: error))
        }
        let answers = reply.answers
        return JevDecision(model: reply.model,
                           tool: answers.tool.choice, toolConfidence: answers.tool.confidence,
                           toolProbabilities: answers.tool.probabilities,
                           needsClarification: answers.needsClarification.noul, inScope: answers.inScope.noul,
                           difficulty: answers.difficulty.score, difficultyConfidence: answers.difficulty.confidence,
                           inputTokens: reply.usage.inputTokens, outputTokens: reply.usage.outputTokens)
    }

    /// The JSON body: `state`, `model` and the four questions, as TypeSafe's docs describe.
    static func body(question: String, previousQuestion: String?) -> [String: Any] {
        let state = previousQuestion.map { "Previous question: \($0)\nQuestion: \(question)" } ?? question
        // Jev's choice criteria map each option name to a description that tells it apart.
        var tools = Dictionary(uniqueKeysWithValues: Tool.all.map { ($0.name, $0.description) })
        tools[AskUser.toolName] = AskUser.claudeSchema["description"] as? String
        tools["none"] = JevWording.noTool
        return [
            "state": state,
            "model": model,
            "questions": [
                "tool": ["type": "choice", "instructions": JevWording.tool, "criteria": tools],
                "needs_clarification": ["type": "noul", "instructions": JevWording.needsClarification],
                "in_scope": ["type": "noul", "instructions": JevWording.inScope],
                "difficulty": ["type": "score", "instructions": JevWording.difficulty, "criteria": JevWording.difficultyLevels],
            ] as [String: Any],
        ]
    }

    /// The parts of Jev's reply that `JevDecision` keeps. Extra fields (such as `type` and `legend`) are ignored.
    private struct Reply: Decodable {
        struct Choice: Decodable { let choice: String; let confidence: Double; let probabilities: [String: Double] }
        struct Noul: Decodable { let noul: Double }
        struct Score: Decodable { let score: Double; let confidence: Double }
        struct Answers: Decodable {
            let tool: Choice, needsClarification: Noul, inScope: Noul, difficulty: Score
            // Spelled out instead of `.convertFromSnakeCase`, which would also rename the
            // option names inside `probabilities` (ask_user would become askUser).
            enum CodingKeys: String, CodingKey {
                case tool, difficulty, needsClarification = "needs_clarification", inScope = "in_scope"
            }
        }
        struct Usage: Decodable {
            let inputTokens: Int, outputTokens: Int
            enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens", outputTokens = "output_tokens" }
        }
        let model: String
        let answers: Answers
        let usage: Usage
    }
}
