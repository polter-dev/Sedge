import Foundation

/// A model the assistant can talk to: Claude now, Apple's on-device model and open models
/// later. Each backend turns the shared conversation below into its own request format,
/// so `Assistant` runs the same loop, with the same tools, whichever model answers.
public protocol ModelBackend: Sendable {
    /// The model id the backend asks for, e.g. "claude-sonnet-5-5".
    var model: String { get }
    /// How hard the model is told to think ("low", "medium", ...), or nil when the model
    /// has no such setting. Recorded in every trace so runs stay comparable.
    var effort: String? { get }
    /// Sends the conversation so far and returns the model's next reply.
    func next(system: String, messages: [ModelMessage]) async throws -> ModelTurn
}

/// One entry in a conversation, in a form that isn't tied to any one model's API.
public enum ModelMessage: Sendable {
    case user(String)
    /// A reply the model gave earlier, sent back so it remembers what it asked for.
    case assistant(ModelTurn)
    /// What the tools returned for the calls in the previous reply.
    case toolResults([ToolResult])
}

/// One reply from a model.
public struct ModelTurn: Sendable {
    /// Any plain text in the reply, joined.
    public var text: String
    public var toolCalls: [ToolCall]
    /// Why the model stopped, using Claude's names: "tool_use", "end_turn", "max_tokens"
    /// or "refusal". Other backends translate theirs into these.
    public var stopReason: String
    /// On a refusal, the reason the API gave (e.g. "cyber"), if any.
    public var refusalCategory: String?
    /// The model id the API says actually answered, which can differ from the one asked for.
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    /// The backend's own copy of the reply, sent back unchanged on the next turn.
    /// Claude needs this because its hidden reasoning blocks must come back exactly as given.
    public var raw: Data

    public init(text: String, toolCalls: [ToolCall], stopReason: String, refusalCategory: String? = nil,
                model: String, inputTokens: Int, outputTokens: Int, raw: Data) {
        self.text = text
        self.toolCalls = toolCalls
        self.stopReason = stopReason
        self.refusalCategory = refusalCategory
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.raw = raw
    }
}

/// A tool the model asked to run, with its inputs as the JSON object the model wrote.
public struct ToolCall: Sendable {
    public let id: String
    public let name: String
    public let input: Data

    public init(id: String, name: String, input: Data) {
        self.id = id
        self.name = name
        self.input = input
    }
}

/// A tool's answer to one `ToolCall`, matched by `id`. Errors are answers too, so the
/// model can read what went wrong and try again.
public struct ToolResult: Sendable {
    public let id: String
    public let content: String
    public let isError: Bool
}
