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

/// True when `text` states `amount`, written exactly or rounded to fewer decimals:
/// 943.45 matches "$943.45", "943.45", "$943.5" and "$943", but not "$944" or "943.46".
func mentions(_ amount: Double, in text: String) -> Bool {
    text.matches(of: /\d[\d,]*(\.\d+)?/).contains { match in
        guard let number = Double(match.output.0.replacingOccurrences(of: ",", with: "")) else { return false }
        let decimals = match.output.1.map { $0.count - 1 } ?? 0
        // Half of the last written digit, plus a little for floating-point error.
        return abs(number - amount) <= 0.5 / pow(10, Double(decimals)) + 1e-9
    }
}

@Test func mentionsAcceptsRoundingButNotOtherAmounts() {
    for text in ["$943.45 left", "943.45", "about $943.5", "You'd have $943 left."] { #expect(mentions(943.45, in: text), "\(text)") }
    for text in ["$944 left", "943.46", "$1,943.45", "$94", "no amount"] { #expect(!mentions(943.45, in: text), "\(text)") }
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
        #expect(mentions(943.45, in: trace.finalAnswer?.answer ?? ""))
        #expect(trace.toolCalls.contains { $0.name == "simulate_balance" && $0.valid })
    }

    @Test func unclearQuestionAsksOnlyOnce() async throws {
        // "Food" could mean groceries too, or only eating out, and the totals differ.
        let question = "How much do I spend on food in a month?"
        let path = FileManager.default.temporaryDirectory.appending(path: "sedge-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        func launch() throws -> SedgeDatabase {
            let database = try SedgeDatabase(path: path)
            try loadPersona("maya", into: database)
            try Organizer.organize(database)
            return database
        }
        let backend = ClaudeBackend(apiKey: try #require(liveKey))
        // Taps the first quick reply, like a person would.
        let person: AskPerson = { $0.options.first }
        let first = await Assistant(backend: backend, database: try launch(), askPerson: person).ask(question)
        print("first:", first.clarifications, first.finalAnswer?.answer ?? first.error ?? "")
        #expect(first.askedUser && first.clarifications.first?.answer != nil)

        // Reopened, as after a restart: a second ask must come from memory, not the person.
        let again = await Assistant(backend: backend, database: try launch(), askPerson: { _ in Issue.record("asked again"); return nil }).ask(question)
        print("again:", again.clarifications, again.finalAnswer?.answer ?? again.error ?? "")
        #expect(again.finalAnswer != nil)
        #expect(again.clarifications.allSatisfy { $0.answeredFromMemory })
    }
}
