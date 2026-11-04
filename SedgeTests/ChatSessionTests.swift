//
//  ChatSessionTests.swift
//  SedgeTests
//

import Foundation
import Testing
@testable import Sedge

/// Stands in for whatever will answer questions: it only reports statuses, in order.
private struct FakeStatusSource {
    let statuses: [AssistantStatus]
    func drive(_ session: ChatSession, each: (AssistantStatus) -> Void) {
        for status in statuses {
            session.report(status)
            each(status)
        }
    }
}

/// Thinking shows the thinking row with one of the ten phrases, the limit shows the limit turn,
/// and "Start new session" clears the turns and lets the person ask again.
@MainActor @Test func statusesDriveTheThinkingRowAndTheLimitTurn() {
    let session = ChatSession()
    session.turns = [ChatTurn(question: "Have I been overspending on food?", answer: ChatAnswer(lead: "More than usual.")),
                     ChatTurn(question: "What about coffee?", answer: nil)]

    FakeStatusSource(statuses: [.thinking, .tokenLimitReached]).drive(session) { status in
        // The Ask screen shows the thinking row exactly when the status is thinking,
        // and the limit turn exactly when it is the token limit.
        #expect(session.status == status)
        if status == .thinking {
            #expect(ChatSession.phrases.contains(session.phrase))
        }
    }
    #expect(session.status == .tokenLimitReached)

    session.startNewSession()
    #expect(session.turns.isEmpty)
    #expect(session.status == .idle)
}

/// Each question gets a phrase from the design's ten, never the one shown for the last question,
/// and the phrase stays put while the same answer is still being worked out.
@MainActor @Test func thinkingPhraseComesFromTheTenAndChangesPerQuestion() {
    #expect(ChatSession.phrases.count == 10)
    let session = ChatSession()
    var last = ""
    for _ in 0..<50 {
        session.report(.thinking)
        let phrase = session.phrase
        #expect(ChatSession.phrases.contains(phrase))
        #expect(phrase != last)
        session.report(.thinking) // still waiting: no new phrase
        #expect(session.phrase == phrase)
        session.report(.idle)
        last = phrase
    }
}

/// One breath of the thinking sprout, out and back, takes 1.2 seconds as in the design.
@MainActor @Test func sproutBreathIsOnePointTwoSecondsRoundTrip() {
    #expect(ThinkingRow.halfBreath * 2 == 1.2)
}

/// Opening an older chat shows its turns with the banner's title and keeps its id, so new
/// questions are added to it; a new chat clears all three.
@MainActor @Test func openingAnOlderChatAndStartingANewOne() {
    let session = ChatSession()
    session.report(.thinking)
    session.open(7, titled: "Have I been overspending on food?",
                 turns: [ChatTurn(question: "Have I been overspending on food?", answer: ChatAnswer(lead: "More than usual."))])
    #expect(session.chatID == 7 && session.reopenedTitle == "Have I been overspending on food?")
    #expect(session.turns.count == 1 && session.status == .idle)

    session.startNewSession()
    #expect(session.chatID == nil && session.reopenedTitle == nil && session.turns.isEmpty)
}

/// A saved answer comes back whole, extras included, so a reopened chat looks as it did.
@MainActor @Test func answerSurvivesSavingAsJSON() throws {
    let answer = ChatAnswer(lead: "More than usual.", point: "Groceries accounts for most of it.", detail: "$64 above.",
                            breakdown: Breakdown(title: "Food & dining", period: "Jun 1–30", total: 486, comparison: "$64 above",
                                                 bars: [ChatBar(label: "Groceries", amount: 300)]),
                            chart: [ChatBar(label: "May", amount: 420)], whatIfLink: "Compare a small change →",
                            quickCheck: QuickCheck(question: "Was this yours?", details: ["Bank · Jun 20"],
                                                   options: ["Yes, mine", "No"], factKey: "own_transfer_2026_06_20"))
    let back = try JSONDecoder().decode(ChatAnswer.self, from: JSONEncoder().encode(answer))
    #expect(back.point == answer.point && back.detail == answer.detail && back.whatIfLink == answer.whatIfLink)
    #expect(back.breakdown?.bars.map(\.amount) == [300] && back.chart?.map(\.label) == ["May"])
    #expect(back.quickCheck?.factKey == "own_transfer_2026_06_20" && back.quickCheck?.options == ["Yes, mine", "No"])
}

/// Previous chats labels a chat by its last use: Today, Yesterday, days ago within the week,
/// then a short date.
@MainActor @Test func previousChatsDateLabels() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 9))!
    func daysBefore(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now)! }
    #expect(PreviousChatsView.when(now.addingTimeInterval(-3600), now: now, calendar: calendar) == "Today")
    #expect(PreviousChatsView.when(daysBefore(1), now: now, calendar: calendar) == "Yesterday")
    #expect(PreviousChatsView.when(daysBefore(2), now: now, calendar: calendar) == "2 days ago")
    #expect(PreviousChatsView.when(daysBefore(9), now: now, calendar: calendar)
            == daysBefore(9).formatted(.dateTime.month(.abbreviated).day()))
}
