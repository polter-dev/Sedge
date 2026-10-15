import Foundation
import FoundationModels

/// Apple's on-device model (Foundation Models), behind the same `ModelBackend` as Claude.
///
/// Apple's `LanguageModelSession` runs tools itself: in the middle of `respond`, it calls each
/// tool's `call` and waits for the answer. To keep the shared `Assistant` loop in charge of
/// running tools (same limits, same checks, same trace as the cloud), each Apple tool here
/// only hands its call over and waits. `next` returns that call as the model's turn, and the
/// next `next` delivers the loop's result back to the waiting tool, so the session carries on
/// exactly as if it had run the tool itself.
///
/// It is an actor because it remembers the conversation in progress between `next` calls.
/// One backend answers one question at a time, which is how the runner and the app use it.
public actor AppleBackend: ModelBackend {
    /// There is one system model, so this name stands for it; its real version is the OS
    /// build, which every reply reports as its model (see `reportedModel`).
    public nonisolated let model = "apple-foundation-models"
    /// The on-device model has no effort setting.
    public nonisolated let effort: String? = nil

    /// What the running session says next: a tool call waiting for its result, or the end.
    enum Event {
        case call(ToolCall, CheckedContinuation<String, any Error>)
        case done(Result<GeneratedContent, any Error>)
    }

    private var events: AsyncStream<Event>?
    private var task: Task<Void, Never>?
    /// Tool calls the session is waiting on, by call id.
    private var waiting: [String: CheckedContinuation<String, any Error>] = [:]

    public init() {}

    /// The model and the OS build it ships in, e.g. "apple-foundation-models, macOS Version
    /// 26.6.2 (Build 25G83)". The model changes with OS updates, so this is its version.
    public nonisolated var reportedModel: String {
        #if os(iOS)
        let system = "iOS"
        #else
        let system = "macOS"
        #endif
        return "\(model), \(system) \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// Why the model can't be used on this device right now, in words for the person, or nil
    /// when it is ready.
    public static func unavailableReason() -> String? {
        explain(SystemLanguageModel.default.availability)
    }

    static func explain(_ availability: SystemLanguageModel.Availability) -> String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Turn it on in System Settings > Apple Intelligence & Siri, then try again."
        case .unavailable(.deviceNotEligible):
            return "This device can't run Apple Intelligence, so Apple's on-device model isn't available."
        case .unavailable(.modelNotReady):
            return "Apple's on-device model is still downloading or getting ready. Try again in a few minutes."
        case .unavailable(let other):
            // A reason added in a later OS.
            return "Apple's on-device model is unavailable (\(other))."
        }
    }

    public func next(system: String, messages: [ModelMessage]) async throws -> ModelTurn {
        if let reason = Self.unavailableReason() { throw AssistantError("model_unavailable: \(reason)") }
        switch messages.last {
        case .user(let question) where messages.count == 1:
            start(system: system, question: question)
        case .toolResults(let results):
            for result in results { waiting.removeValue(forKey: result.id)?.resume(returning: result.content) }
        default:
            throw AssistantError("The on-device model can only continue its own conversation.")
        }

        // A copy of the iterator reads the same stream; it is copied because an actor's stored
        // value can't be changed across an `await`.
        var iterator = events?.makeAsyncIterator()
        switch await iterator?.next() {
        case .call(let call, let continuation):
            waiting[call.id] = continuation
            return turn(calls: [call], stop: "tool_use")
        case .done(.success(let content)):
            // The final answer arrives as the structured reply, passed on unchanged as a
            // final_answer call so the loop checks it exactly like Claude's.
            stop()
            let call = ToolCall(id: "final", name: FinalAnswer.toolName, input: Data(content.jsonString.utf8))
            return turn(calls: [call], stop: "tool_use")
        case .done(.failure(let error)):
            stop()
            throw AssistantError(Self.label(error))
        case nil:
            // The session already ended, e.g. its final answer was rejected: it can't retry.
            throw AssistantError("bad_arguments: the final answer was rejected and the session has ended.")
        }
    }

    /// Starts a new session for a new question, ending any earlier one first.
    private func start(system: String, question: String) {
        stop()
        let (stream, events) = AsyncStream<Event>.makeStream()
        self.events = stream
        let tools = Tool.all.map { AppleTool(tool: $0, events: events) }
        task = Task {
            do {
                let session = LanguageModelSession(model: .default, tools: tools, instructions: system)
                // Greedy decoding: the same question gets the same answer on every run.
                let response = try await session.respond(to: question, generating: AppleFinalAnswer.self,
                                                         options: GenerationOptions(samplingMode: .greedy))
                events.yield(.done(.success(response.rawContent)))
            } catch {
                events.yield(.done(.failure(error)))
            }
            events.finish()
        }
    }

    /// Ends the current session, so no tool is left waiting forever.
    private func stop() {
        for continuation in waiting.values { continuation.resume(throwing: CancellationError()) }
        waiting = [:]
        task?.cancel()
        task = nil
    }

    private func turn(calls: [ToolCall], stop: String) -> ModelTurn {
        // shortcut: token counts are 0, since macOS 26 doesn't report usage; count them with
        // `SystemLanguageModel.tokenCount(for:)` if the context-window analysis needs them.
        ModelTurn(text: "", toolCalls: calls, stopReason: stop, model: reportedModel,
                  inputTokens: 0, outputTokens: 0, raw: Data())
    }

    /// One short label in front of the framework's own message, so the runner can count
    /// failures by kind: context_window, guardrail, refusal, model_unavailable, bad_arguments,
    /// tool_error. Anything else (rate limits, a busy session) is left unlabeled, like a
    /// network error from the cloud, because it says nothing about the model.
    static func label(_ error: any Error) -> String {
        let label: String?
        switch error {
        case let error as LanguageModelSession.GenerationError:
            switch error {
            case .exceededContextWindowSize: label = "context_window"
            case .guardrailViolation: label = "guardrail"
            case .refusal: label = "refusal"
            case .assetsUnavailable: label = "model_unavailable"
            case .decodingFailure, .unsupportedGuide: label = "bad_arguments"
            default: label = nil
            }
        case is LanguageModelSession.ToolCallError: label = "tool_error"
        default: label = newLabel(error)
        }
        return label.map { "\($0): \(error)" } ?? "\(error)"
    }

    /// The same labels for the error types iOS and macOS 27 throw instead.
    private static func newLabel(_ error: any Error) -> String? {
        guard #available(iOS 27, macOS 27, *) else { return nil }
        switch error {
        case let error as LanguageModelError:
            switch error {
            case .contextSizeExceeded: return "context_window"
            case .guardrailViolation: return "guardrail"
            case .refusal: return "refusal"
            case .unsupportedGenerationGuide: return "bad_arguments"
            default: return nil
            }
        case is SystemLanguageModel.Error: return "model_unavailable"
        case is GeneratedContent.ParsingError: return "bad_arguments"
        default: return nil
        }
    }
}

/// One of the six tools as Apple's model sees it. Its inputs are built from the same
/// `ToolInput` list as Claude's schema, so the two can't drift apart.
struct AppleTool: FoundationModels.Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let events: AsyncStream<AppleBackend.Event>.Continuation

    init(tool: Tool, events: AsyncStream<AppleBackend.Event>.Continuation) {
        name = tool.name
        description = tool.description
        // The definitions are fixed and tested, so a schema error here is a programming mistake.
        parameters = try! Self.schema(for: tool)
        self.events = events
    }

    /// Hands the call to `AppleBackend.next` and waits for the loop's answer.
    func call(arguments: GeneratedContent) async throws -> String {
        let call = ToolCall(id: UUID().uuidString, name: name, input: Data(arguments.jsonString.utf8))
        return try await withCheckedThrowingContinuation { events.yield(.call(call, $0)) }
    }

    /// The tool's inputs as a schema the model must follow while it writes the call.
    static func schema(for tool: Tool) throws -> GenerationSchema {
        let properties = tool.inputs.map { input in
            DynamicGenerationSchema.Property(name: input.name, description: input.description,
                                             schema: schema(for: input, in: tool), isOptional: !input.required)
        }
        return try GenerationSchema(root: DynamicGenerationSchema(name: tool.name, properties: properties), dependencies: [])
    }

    private static func schema(for input: ToolInput, in tool: Tool) -> DynamicGenerationSchema {
        switch input.kind {
        case .text: DynamicGenerationSchema(type: String.self)
        case .date: DynamicGenerationSchema(type: String.self, guides: [.pattern(/\d{4}-\d{2}-\d{2}/)])
        case .integer(let range): DynamicGenerationSchema(type: Int.self, guides: [.range(range)])
        case .number: DynamicGenerationSchema(type: Double.self)
        // A list of choices is a named type; the tool's name keeps it unique.
        case .choice(let options): DynamicGenerationSchema(name: "\(tool.name)_\(input.name)", anyOf: options)
        }
    }
}

/// The final answer as Apple's model writes it: the same fields and descriptions as the
/// `final_answer` tool Claude calls, so `FinalAnswer.parse` reads both the same way.
@Generable(description: "Give the final answer to the question.")
struct AppleFinalAnswer {
    @Guide(description: "One plain sentence for the person.")
    var answer: String
    @Guide(description: "The main number in the answer, in dollars or a count, or null.")
    var value: Double?
    @Guide(description: "The names, when the question asks for a list, or null.")
    var items: [String]?
    @Guide(description: "true or false for a yes-or-no question, otherwise null.")
    var yes_no: Bool?
    @Guide(description: "How sure you are, from 0 to 1, or null.", .range(0...1))
    var confidence: Double?
}
