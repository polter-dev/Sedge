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
/// and reporting thinking again for the same answer doesn't pick another.
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

/// While thinking, the phrase changes after every 2.2-second wait, never to the one just shown.
/// It doesn't change while idle, and the cycling stops as soon as thinking ends or the row goes
/// away. The waits are stepped by the test instead of really sleeping.
@MainActor @Test func thinkingPhraseCyclesUntilThinkingEnds() async {
    let session = ChatSession()
    var waits = 0
    await session.cyclePhrases { _ in waits += 1 }
    #expect(waits == 0 && session.phrase == "") // idle: returns at once, nothing changes

    session.report(.thinking)
    var shown: [String] = []
    await session.cyclePhrases { wait in
        #expect(wait == .seconds(2.2))
        shown.append(session.phrase)
        if shown.count == 200 { session.report(.idle) } // thinking ends during this wait
    }
    #expect(shown.count == 200)
    #expect(shown.allSatisfy(ChatSession.phrases.contains))
    #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 != $1 })
    #expect(session.phrase == shown.last) // no change after thinking ended

    // The row going away cancels the wait, which also stops the cycling without a change.
    session.report(.thinking)
    let before = session.phrase
    await session.cyclePhrases { _ in throw CancellationError() }
    #expect(session.phrase == before)
}

/// One sprout cycle takes 3.4 seconds: the ground draws first, then the stem, the right leaf and
/// the left leaf; all four hold fully drawn, then erase in the same order and are gone by the end.
@MainActor @Test func sproutDrawsPartByPartThenErases() {
    #expect(ThinkingSprout.cycleSeconds == 3.4 && ThinkingRow.shimmerSeconds == 1.9)
    let shown = { (t: Double) in ThinkingSprout.parts.map { $0.shown(at: t) } }
    #expect(shown(0) == [0, 0, 0, 0])
    #expect(shown(0.07)[0] == 0.5 && shown(0.07)[1...] == [0, 0, 0]) // ground halfway
    let midRightLeaf = shown(0.42) // ground and stem done, right leaf halfway, left not started
    #expect(midRightLeaf[0] == 1 && midRightLeaf[1] == 1 && abs(midRightLeaf[2] - 0.5) < 1e-9 && midRightLeaf[3] == 0)
    #expect(shown(0.75) == [1, 1, 1, 1])
    #expect(shown(0.85)[0] < shown(0.85)[3]) // the ground is half erased while the left leaf has barely started
    #expect(shown(0.99) == [0, 0, 0, 0])
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
