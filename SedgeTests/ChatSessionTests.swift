//
//  ChatSessionTests.swift
//  SedgeTests
//

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
