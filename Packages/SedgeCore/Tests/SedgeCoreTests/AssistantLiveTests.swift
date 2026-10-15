import Foundation
import Testing
@testable import SedgeCore

// Real calls to Claude. They cost money, so they run only when asked for:
//   SEDGE_LIVE_TESTS=1 ANTHROPIC_API_KEY=... swift test --package-path Packages/SedgeCore --filter Live
// Each prints its trace (the key is never part of one).

let liveKey = ProcessInfo.processInfo.environment["SEDGE_LIVE_TESTS"] == "1" ? ClaudeBackend.apiKey() : nil

func liveAsk(_ persona: String, _ question: String, asOf: String = Persona.asOf) async throws -> Trace {
    let assistant = Assistant(backend: ClaudeBackend(apiKey: try #require(liveKey)), database: try organizedPersona(persona, asOf: asOf))
    let trace = await assistant.ask(question)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(trace), as: UTF8.self))
    return trace
}

@Suite(.enabled(if: liveKey != nil, "Set SEDGE_LIVE_TESTS=1 and ANTHROPIC_API_KEY"), .serialized)
struct LiveClaude {
    @Test func mayaNetflixFirstHalf() async throws {
        let trace = try await liveAsk("maya", "How much did I spend at Netflix from January through June?")
        #expect(trace.error == nil)
        #expect(trace.finalAnswer?.value == 100.44)
        #expect(trace.toolCalls.contains { $0.name == "total_spent" && $0.valid })
    }

    @Test func danielTwoStoreComparison() async throws {
        // Truth from daniel's own data and answer key (a training persona).
        let rows = try truth("daniel").filter { $0.date >= "2026-01-01" && $0.date <= "2026-06-30" }
        let cafe = spent(rows.filter { $0.merchant == "Corner Cafe" }), shell = spent(rows.filter { $0.merchant == "Shell" })
        let trace = try await liveAsk("daniel", "Did I spend more at Corner Cafe than at Shell from January through June?")
        #expect(trace.error == nil)
        #expect(trace.finalAnswer?.yes_no == (cafe > shell))
    }

    @Test func incomeComesFromTheProfile() async throws {
        let trace = try await liveAsk("maya", "What's my income?")
        #expect(trace.error == nil)
        #expect(trace.finalAnswer != nil)
        #expect(trace.toolCalls.contains { $0.name == "get_profile" && $0.valid })
    }

    @Test func misspelledStoreIsRetried() async throws {
        // The tool rejects the misspelled name and suggests "Netflix"; the model should retry with it.
        let trace = try await liveAsk("maya", "How much did I spend at Netflx from January through June?")
        #expect(trace.error == nil)
        #expect(trace.finalAnswer?.value == 100.44)
    }

    @Test func mayaRentWhatIf() async throws {
        // The proposal's question a week before rent day (Wed Jun 24; rent is due Jul 1).
        // By hand: 1993.45 - 400 - 650 rent = 943.45 left (see mayaRentQuestion).
        let trace = try await liveAsk("maya", "If I spend $400 on Friday, can I still pay rent this month?", asOf: "2026-06-24")
        #expect(trace.error == nil)
        #expect(trace.finalAnswer?.yes_no == true)
        #expect(trace.finalAnswer?.answer.contains("943.45") == true)
        #expect(trace.toolCalls.contains { $0.name == "simulate_balance" && $0.valid })
    }
}
