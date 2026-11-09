//
//  AskKeepAwakeTests.swift
//  SedgeTests
//

import SwiftUI
import Testing
@testable import Sedge

/// Picking other data ends Ask's question (`AskScreenState.end()`); the UI test
/// `testChangingDataMidQuestionLetsTheScreenLock` covers the screen itself.
@MainActor @Suite(.serialized) struct AskKeepAwake {
    @Test func endingAskStopsTheQuestionAndLetsTheScreenLock() async {
        let screen = AskScreenState()
        screen.session.report(.thinking)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        screen.question = Task { try? await Task.sleep(for: .seconds(60)) }
        // The question waits on a quick check.
        let reply = Task {
            await screen.session.ask(QuickCheck(question: "Should food include groceries?", details: [],
                                                options: ["Groceries too", "Eating out only"], factKey: "food_includes_groceries"))
        }
        while screen.session.pendingCheck == nil { await Task.yield() }

        screen.end()

        #expect(await reply.value == nil, "the quick check should take Later")
        #expect(screen.question?.isCancelled == true)
        #expect(UIApplication.shared.isIdleTimerDisabled == false)
        #expect(screen.session.status == .idle)
    }
}
