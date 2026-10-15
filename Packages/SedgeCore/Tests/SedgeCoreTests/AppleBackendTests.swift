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
    // A busy model says nothing about the model's skill, so it stays unlabeled (an api_error).
    #expect(AppleBackend.label(Failure.rateLimited(context)).hasPrefix("rateLimited("))
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
