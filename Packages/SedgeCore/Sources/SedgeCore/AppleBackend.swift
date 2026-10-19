import Foundation
import FoundationModels

/// Apple's on-device model (Foundation Models), behind the same `ModelBackend` as Claude.
///
/// Apple's `LanguageModelSession` runs tools itself: in the middle of `respond`, it calls each
/// tool's `call` and waits for the answer. To keep the shared `Assistant` loop in charge of
/// running tools (same limits, same checks, same trace as the cloud), each Apple tool here
/// only hands its call over and waits. `next` returns that call as the model's turn, and the
/// next `next` delivers the loop's result back to the waiting tool, so the session carries on
/// exactly as if it had run the tool itself. Calls the model makes together in one response
/// (the session runs them at the same time) go out as one turn, the way Claude sends them, so
/// the loop's reply limit costs both models the same for the same calls. If one of them is more
/// than a second late, the turn goes without it and is marked split, which the trace counts.
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
        /// Sent a while after the first of several calls made together (by its call id), so a
        /// call that never comes can't hold the turn forever.
        case late(String)
    }

    /// An open conversation with the model. It is kept for the whole question, so a retry
    /// continues the same conversation.
    struct Session: Sendable {
        /// One reply: the structured final answer, with any tool calls made on the way.
        var respond: @Sendable (_ prompt: String) async throws -> GeneratedContent
        /// The calls in the model's latest response, in its order, each as `key(name:input:)`.
        /// Empty means each call came alone.
        var latestCalls: @Sendable () -> [String] = { [] }
    }
    /// Opens a session with this system prompt and these tools. Tests pass a scripted one.
    typealias MakeSession = @Sendable (_ system: String, _ tools: [any FoundationModels.Tool]) -> Session

    private let makeSession: MakeSession
    private var session: Session?
    private var events: AsyncStream<Event>?
    /// The tools and the session write their events here.
    private var feed: AsyncStream<Event>.Continuation?
    private var task: Task<Void, Never>?
    /// Tool calls the session is waiting on, by call id.
    private var waiting: [String: CheckedContinuation<String, any Error>] = [:]
    /// Calls of the latest group that a split turn went out without (see `next`), by `key`.
    private var leftover: [String] = []
    /// The id the final answer goes out under, so its rejection can be told from a tool result.
    static let finalID = "final"

    public init() { makeSession = Self.systemSession }
    init(makeSession: @escaping MakeSession) { self.makeSession = makeSession }

    /// A session with Apple's system model.
    static let systemSession: MakeSession = { system, tools in
        let session = LanguageModelSession(model: .default, tools: tools, instructions: system)
        return Session(respond: { prompt in
            if let reason = unavailableReason() { throw AssistantError("model_unavailable: \(reason)") }
            // Greedy decoding: the same question gets the same answer on every run.
            return try await session.respond(to: prompt, generating: AppleFinalAnswer.self,
                                             options: GenerationOptions(samplingMode: .greedy)).rawContent
        }, latestCalls: {
            // The session writes a response's calls to its transcript before it runs them.
            for entry in session.transcript.reversed() {
                if case .toolCalls(let calls) = entry {
                    return calls.map { key(name: $0.toolName, input: $0.arguments.jsonString) }
                }
            }
            return []
        })
    }

    /// One call's name and inputs as a single string, to find it among the latest calls. The
    /// inputs' keys are sorted first: the same inputs come out of `jsonString` in any key order.
    static func key(name: String, input: String) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(input.utf8))
        let sorted = object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
        return name + " " + (sorted.map { String(decoding: $0, as: UTF8.self) } ?? input)
    }

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
        switch messages.last {
        case .user(let question) where messages.count == 1:
            start(system: system, question: question)
        case .toolResults(let results):
            var resumed = false
            for result in results {
                guard let continuation = waiting.removeValue(forKey: result.id) else { continue }
                continuation.resume(returning: result.content)
                resumed = true
            }
            // A rejected final answer goes back to the same session as the next prompt, so the
            // model gets the retry Claude gets when the loop sends it the error as a tool result.
            if let rejected = results.first(where: { $0.id == Self.finalID }) {
                respond(to: rejected.content)
                resumed = true
            }
            // Nothing in the session would reply, so waiting below would never end.
            guard resumed else { throw AssistantError("The on-device session isn't waiting for these results.") }
        default:
            throw AssistantError("The on-device model can only continue its own conversation.")
        }

        // A copy of the iterator reads the same stream; it is copied because an actor's stored
        // value can't be changed across an `await`.
        var iterator = events?.makeAsyncIterator()
        var calls: [ToolCall] = []
        var together: [String] = []
        var gaveUp = false
        repeat {
            switch await iterator?.next() {
            case .call(let call, let continuation):
                waiting[call.id] = continuation
                calls.append(call)
                // The first call's response says how many more calls are on their way. It is
                // trusted only if it holds that call, in case the transcript is behind. After a
                // split turn, only the group's calls still to come are waited for.
                if calls.count == 1 {
                    if leftover.contains(Self.key(call)) {
                        together = leftover
                    } else if let latest = session?.latestCalls(), latest.contains(Self.key(call)) {
                        together = latest
                    }
                }
                if calls.count == 1, together.count > 1 {
                    // The calls start at the same moment. If one hasn't come after a second,
                    // the session is running them one at a time (it would wait for this
                    // result first), so the turn goes out with what has arrived.
                    Task { [feed] in
                        try? await Task.sleep(for: .seconds(1))
                        feed?.yield(.late(call.id))
                    }
                }
            case .late(let id):
                // One left over from an earlier turn is ignored.
                gaveUp = id == calls.first?.id
            case .done(.success(let content)):
                // The final answer arrives as the structured reply, passed on unchanged as a
                // final_answer call so the loop checks it exactly like Claude's. The session
                // stays open in case the loop rejects it.
                let call = ToolCall(id: Self.finalID, name: FinalAnswer.toolName, input: Data(content.jsonString.utf8))
                leftover = []
                return turn(calls: [call], stop: "tool_use")
            case .done(.failure(let error)):
                stop()
                throw AssistantError(Self.label(error))
            case nil:
                throw AssistantError("The on-device session has already ended.")
            }
        } while calls.isEmpty || (!gaveUp && calls.count < together.count)
        // The session runs calls at the same time, so they can arrive in any order; put them
        // back in the model's order so the loop runs (and limits) them the same way every time.
        calls.sort { (together.firstIndex(of: Self.key($0)) ?? .max) < (together.firstIndex(of: Self.key($1)) ?? .max) }
        // Calls of the group that didn't make it in time. They will come as one more turn, which
        // Claude wouldn't take for the same calls, so the turn is marked for the trace to count.
        leftover = together
        for call in calls { leftover.firstIndex(of: Self.key(call)).map { leftover.remove(at: $0) } }
        var result = turn(calls: calls, stop: "tool_use")
        result.splitTurn = !leftover.isEmpty
        return result
    }

    private static func key(_ call: ToolCall) -> String {
        key(name: call.name, input: String(decoding: call.input, as: UTF8.self))
    }

    /// Starts a new session for a new question, ending any earlier one first. It is offered
    /// the same tools as Claude's cloud setup: the data tools and ask_user.
    private func start(system: String, question: String) {
        stop()
        leftover = []
        let (stream, feed) = AsyncStream<Event>.makeStream()
        events = stream
        self.feed = feed
        let tools = Tool.all.map { AppleTool(tool: $0, events: feed) } + [AppleTool.askUser(events: feed)]
        session = makeSession(system, tools)
        respond(to: question)
    }

    /// Asks the open session for its next reply, which arrives as events.
    private func respond(to prompt: String) {
        guard let session, let feed else { return }
        task = Task {
            do {
                feed.yield(.done(.success(try await session.respond(prompt))))
            } catch {
                feed.yield(.done(.failure(error)))
            }
        }
    }

    /// Ends the current session, so no tool is left waiting forever.
    private func stop() {
        for continuation in waiting.values { continuation.resume(throwing: CancellationError()) }
        waiting = [:]
        task?.cancel()
        task = nil
        feed?.finish()
        feed = nil
        session = nil
    }

    private func turn(calls: [ToolCall], stop: String) -> ModelTurn {
        // shortcut: token counts are 0, since macOS 26 doesn't report usage; count them with
        // `SystemLanguageModel.tokenCount(for:)` if the context-window analysis needs them.
        ModelTurn(text: "", toolCalls: calls, stopReason: stop, model: reportedModel,
                  inputTokens: 0, outputTokens: 0, raw: Data())
    }

    /// One short label in front of the framework's own message, so the runner can count
    /// failures by kind. The labels fall in two groups, and the runner treats them differently
    /// when a stopped run is resumed:
    /// - Final: the failure can come from the question itself, so asking again would give the
    ///   same failure, or keep re-asking until one run happens to pass. These count as the
    ///   model's failure and are kept: context_window, guardrail, refusal, bad_arguments,
    ///   tool_error, unsupported_language (the model decides the question's language),
    ///   unsupported_capability and unsupported_content (what the conversation asked for or
    ///   held, which the question shapes).
    /// - Transient: the device was busy or not ready, which says nothing about the question,
    ///   so resume asks again, like a cloud network error: model_unavailable, rate_limited,
    ///   busy (another request on the same session), timeout.
    /// Anything else is left unlabeled and becomes an api_error, which resume also asks again.
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
            case .unsupportedLanguageOrLocale: label = "unsupported_language"
            case .rateLimited: label = "rate_limited"
            case .concurrentRequests: label = "busy"
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
            case .unsupportedLanguageOrLocale: return "unsupported_language"
            case .unsupportedCapability: return "unsupported_capability"
            case .unsupportedTranscriptContent: return "unsupported_content"
            case .rateLimited: return "rate_limited"
            case .timeout: return "timeout"
            @unknown default: return nil
            }
        case let error as LanguageModelSession.Error where error == .concurrentRequests: return "busy"
        case is SystemLanguageModel.Error: return "model_unavailable"
        case is GeneratedContent.ParsingError: return "bad_arguments"
        default: return nil
        }
    }
}

/// One of the `Tool.all` data tools, or `ask_user`, as Apple's model sees it. Its inputs are built
/// from the same definitions as Claude's schema, so the two can't drift apart.
struct AppleTool: FoundationModels.Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let events: AsyncStream<AppleBackend.Event>.Continuation

    /// Hands the call to `AppleBackend.next` and waits for the loop's answer.
    func call(arguments: GeneratedContent) async throws -> String {
        let call = ToolCall(id: UUID().uuidString, name: name, input: Data(arguments.jsonString.utf8))
        return try await withCheckedThrowingContinuation { events.yield(.call(call, $0)) }
    }
}

extension AppleTool {
    // In an extension, so the struct keeps its memberwise init for `askUser`.
    init(tool: Tool, events: AsyncStream<AppleBackend.Event>.Continuation) {
        // The definitions are fixed and tested, so a schema error here is a programming mistake.
        self.init(name: tool.name, description: tool.description, parameters: try! Self.schema(for: tool), events: events)
    }

    /// `ask_user`, with the name and descriptions taken from Claude's definition. Like
    /// Claude's, the options list has no length limit in the schema; `AskUser.run` checks it.
    static func askUser(events: AsyncStream<AppleBackend.Event>.Continuation) -> AppleTool {
        let claude = AskUser.claudeSchema
        let properties = (claude["input_schema"] as! [String: Any])["properties"] as! [String: [String: Any]]
        func property(_ name: String, _ schema: DynamicGenerationSchema) -> DynamicGenerationSchema.Property {
            DynamicGenerationSchema.Property(name: name, description: properties[name]?["description"] as? String, schema: schema)
        }
        let text = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(name: AskUser.toolName, properties: [
            property("question", text), property("options", DynamicGenerationSchema(arrayOf: text)), property("fact_key", text),
        ])
        return AppleTool(name: AskUser.toolName, description: claude["description"] as! String,
                         parameters: try! GenerationSchema(root: root, dependencies: []), events: events)
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
