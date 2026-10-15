import Foundation
import Testing
@testable import SedgeCore

// Real calls to Claude. They cost money, so they run only when asked for:
//   SEDGE_LIVE_TESTS=1 ANTHROPIC_API_KEY=... swift test --package-path Packages/SedgeCore --filter Live
// Each prints its trace (the key is never part of one).

let liveKey = ProcessInfo.processInfo.environment["SEDGE_LIVE_TESTS"] == "1" ? ClaudeBackend.apiKey() : nil

func liveAsk(_ persona: String, _ question: String) async throws -> Trace {
    let assistant = Assistant(backend: ClaudeBackend(apiKey: try #require(liveKey)), database: try organizedPersona(persona))
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

    @Test func misspelledStoreIsRetried() async throws {
        // The tool rejects the misspelled name and suggests "Netflix"; the model should retry with it.
        let trace = try await liveAsk("maya", "How much did I spend at Netflx from January through June?")
        #expect(trace.error == nil)
        #expect(trace.finalAnswer?.value == 100.44)
    }
}
