import Foundation
import FoundationModels
import Testing
@testable import SedgeCore

// The parts of the on-device backend that don't need the model, then (when asked for) real
// questions to Apple's model, which runs on this Mac for free:
//   SEDGE_LIVE_TESTS=1 swift test --package-path Packages/SedgeCore --filter LiveApple

@Test func everyToolHasAnAppleSchema() throws {
    for tool in Tool.all { _ = try AppleTool.schema(for: tool) }
}

@Test func everyAvailabilityProblemHasAReason() {
    #expect(AppleBackend.explain(.available) == nil)
    #expect(AppleBackend.explain(.unavailable(.appleIntelligenceNotEnabled))?.contains("Apple Intelligence is turned off") == true)
    #expect(AppleBackend.explain(.unavailable(.deviceNotEligible)) != nil)
    #expect(AppleBackend.explain(.unavailable(.modelNotReady)) != nil)
}

@Test func frameworkErrorsGetLabels() {
    typealias Failure = LanguageModelSession.GenerationError
    let context = Failure.Context(debugDescription: "test")
    #expect(AppleBackend.label(Failure.exceededContextWindowSize(context)).hasPrefix("context_window: "))
    #expect(AppleBackend.label(Failure.guardrailViolation(context)).hasPrefix("guardrail: "))
    #expect(AppleBackend.label(Failure.refusal(.init(transcriptEntries: []), context)).hasPrefix("refusal: "))
    #expect(AppleBackend.label(Failure.assetsUnavailable(context)).hasPrefix("model_unavailable: "))
    #expect(AppleBackend.label(Failure.decodingFailure(context)).hasPrefix("bad_arguments: "))
    let tool = AppleTool(tool: .accountBalances, events: AsyncStream.makeStream(of: AppleBackend.Event.self).continuation)
    #expect(AppleBackend.label(LanguageModelSession.ToolCallError(tool: tool, underlyingError: CancellationError())).hasPrefix("tool_error: "))
    // Each failure gets its own label, so the runner can tell a busy device (asked again on
    // resume) from a question the model can't handle (kept as the model's failure).
    #expect(AppleBackend.label(Failure.rateLimited(context)).hasPrefix("rate_limited: "))
    #expect(AppleBackend.label(Failure.concurrentRequests(context)).hasPrefix("busy: "))
    #expect(AppleBackend.label(Failure.unsupportedLanguageOrLocale(context)).hasPrefix("unsupported_language: "))
}

/// Records each prompt a scripted session is sent, so a reply can depend on how many came before.
private actor Prompts {
    var sent: [String] = []
    func add(_ prompt: String) -> Int { sent.append(prompt); return sent.count }
}

@Test func rejectedFinalAnswerGetsARetryInTheSameSession() async throws {
    let prompts = Prompts()
    let backend = AppleBackend { _, _ in
        { prompt in
            // The first answer breaks the 0-to-1 confidence rule; the retry fixes it.
            let confidence = await prompts.add(prompt) == 1 ? 5 : 0.9
            return try GeneratedContent(json: #"{"answer": "You spent $100.44.", "value": 100.44, "confidence": \#(confidence)}"#)
        }
    }
    let trace = await Assistant(backend: backend, database: try organizedPersona("maya")).ask("Netflix, Jan to Jun?")
    #expect(trace.error == nil && trace.finalAnswer?.value == 100.44)
    #expect(trace.toolCalls.map(\.valid) == [false, true])
    // The model was shown the same error Claude would see as its tool result.
    let sent = await prompts.sent
    #expect(sent.count == 2 && sent[1].contains("Bad value for"))
}

@Test func askUserIsOfferedAndAnsweredThroughTheLoop() async throws {
    let backend = AppleBackend { _, tools in
        { _ in
            // Same tools as the cloud setup: the data tools, then ask_user.
            #expect(tools.map(\.name) == Tool.all.map(\.name) + [AskUser.toolName])
            let askUser = try #require(tools.last as? AppleTool)
            let input = #"{"question": "Count groceries as food?", "options": ["Yes", "No"], "fact_key": "food_includes_groceries"}"#
            let reply = try await askUser.call(arguments: GeneratedContent(json: input))
            #expect(reply.contains("Yes"))
            return try GeneratedContent(json: #"{"answer": "You spent $100.44.", "value": 100.44}"#)
        }
    }
    let trace = await Assistant(backend: backend, database: try organizedPersona("maya"), askPerson: { _ in "Yes" })
        .ask("How much did I spend on food?")
    #expect(trace.error == nil && trace.finalAnswer?.value == 100.44)
    #expect(trace.askedUser && trace.clarifications.first?.answer == "Yes")
    #expect(trace.toolCalls.map(\.name) == [AskUser.toolName, FinalAnswer.toolName])
}

@Test func askUserHasAnAppleSchema() {
    let tool = AppleTool.askUser(events: AsyncStream.makeStream(of: AppleBackend.Event.self).continuation)
    #expect(tool.name == AskUser.toolName && tool.description == AskUser.claudeSchema["description"] as? String)
}

let liveApple = ProcessInfo.processInfo.environment["SEDGE_LIVE_TESTS"] == "1" && AppleBackend.unavailableReason() == nil

@Suite(.enabled(if: liveApple, "Set SEDGE_LIVE_TESTS=1 and turn on Apple Intelligence"), .serialized)
struct LiveApple {
    @Test func answersThroughTheSharedLoop() async throws {
        let backend = AppleBackend()
        let trace = await Assistant(backend: backend, database: try organizedPersona("maya"))
            .ask("How much did I spend at Netflix from January through June?")
        #expect(trace.error == nil && trace.finalAnswer != nil)
        #expect(trace.toolCalls.last?.name == FinalAnswer.toolName)
        #expect(trace.reportedModel == backend.reportedModel)

        // The same backend starts a fresh session for the next question.
        let second = await Assistant(backend: backend, database: try organizedPersona("maya")).ask("What are my account balances?")
        #expect(second.error == nil && second.toolCalls.contains { $0.name == "account_balances" })
    }

    @Test func tooLongAQuestionIsLabeled() async throws {
        let question = String(repeating: "How much did I spend at Netflix? ", count: 600)
        let trace = await Assistant(backend: AppleBackend(), database: try organizedPersona("maya")).ask(question)
        #expect(trace.error?.hasPrefix("context_window: ") == true)
    }
}
