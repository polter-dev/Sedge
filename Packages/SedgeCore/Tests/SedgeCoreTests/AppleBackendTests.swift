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
        .init { prompt in
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
        .init { _ in
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

// The same model behavior through both backends: seven data calls in one response (the
// seventh over the limit), then a rejected final answer, then a good one. Claude sends calls
// made together as one turn, so Apple's must be one turn too, or Apple runs out of replies
// (`tool_limit`) where Claude goes on to answer.
private let sevenStores = ["Netflix", "Spotify", "Trader Joe's", "Safeway", "Shell", "Chipotle", "Amazon"]
    .map { #"{"merchant": "\#($0)", "start_date": "2026-01-01", "end_date": "2026-06-30"}"# }
private let badConfidence = #"{"answer": "x", "value": 100.44, "items": null, "yes_no": null, "confidence": 5}"#

@Test func batchedBackendFinishes() async throws {
    let backend = ScriptedBackend([calling(sevenStores.map { ("total_spent", $0) }),
                                   calling([("final_answer", badConfidence)]), calling([("final_answer", answer100)])])
    let trace = await Assistant(backend: backend, database: try organizedPersona("maya")).ask("?")
    #expect(trace.error == nil && trace.finalAnswer?.value == 100.44 && trace.turns == 3)
}

/// Counts a scripted session's replies.
private actor Count {
    var n = 0
    func next() -> Int { n += 1; return n }
}

@Test func appleCallsMadeTogetherAreOneTurn() async throws {
    let count = Count()
    let backend = AppleBackend { _, tools in
        .init(respond: { _ in
            let tool = try #require(tools.first { $0.name == "total_spent" } as? AppleTool)
            if await count.next() == 1 {
                // Like the real session, run the calls at the same time; started backwards so
                // they arrive out of the model's order.
                try await withThrowingTaskGroup(of: String.self) { group in
                    for input in sevenStores.reversed() { group.addTask { try await tool.call(arguments: GeneratedContent(json: input)) } }
                    try await group.waitForAll()
                }
                return try GeneratedContent(json: badConfidence)
            }
            return try GeneratedContent(json: #"{"answer": "You spent $100.44.", "value": 100.44, "confidence": 0.9}"#)
        }, latestCalls: { sevenStores.map { AppleBackend.key(name: "total_spent", input: $0) } })
    }
    let trace = await Assistant(backend: backend, database: try organizedPersona("maya")).ask("?")
    #expect(trace.error == nil && trace.finalAnswer?.value == 100.44, "error=\(trace.error ?? "nil") turns=\(trace.turns)")
    #expect(trace.turns == 3)
    // In the model's order, so the call refused for being over the limit is always the seventh.
    let merchants = trace.toolCalls.prefix(7).map {
        (try? JSONSerialization.jsonObject(with: Data($0.input.utf8)) as? [String: Any])?["merchant"] as? String
    }
    #expect(merchants == ["Netflix", "Spotify", "Trader Joe's", "Safeway", "Shell", "Chipotle", "Amazon"])
    #expect(trace.toolCalls.map { $0.error == "No tool calls left." } == Array(repeating: false, count: 6) + [true, false, false])
}

@Test func callsRunOneAtATimeStillGetAnswered() async throws {
    // A session that says two calls were made together but runs them one after the other, so
    // the second only comes once the first has its result.
    let two = Array(sevenStores.prefix(2))
    let backend = AppleBackend { _, tools in
        .init(respond: { _ in
            let tool = try #require(tools.first { $0.name == "total_spent" } as? AppleTool)
            for input in two { _ = try await tool.call(arguments: GeneratedContent(json: input)) }
            return try GeneratedContent(json: #"{"answer": "You spent $100.44.", "value": 100.44, "confidence": 0.9}"#)
        }, latestCalls: { two.map { AppleBackend.key(name: "total_spent", input: $0) } })
    }
    let trace = await Assistant(backend: backend, database: try organizedPersona("maya")).ask("?")
    #expect(trace.error == nil && trace.finalAnswer?.value == 100.44)
    #expect(trace.toolCalls.map(\.name) == ["total_spent", "total_spent", FinalAnswer.toolName])
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
