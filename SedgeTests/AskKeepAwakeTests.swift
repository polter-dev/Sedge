//
//  AskKeepAwakeTests.swift
//  SedgeTests
//

import SedgeCore
import SwiftUI
import Testing
@testable import Sedge

/// The screen stays awake while a question is worked out. Picking other data mid-answer rebuilds the
/// tabs, and the Ask screen that kept it awake goes; the screen must be allowed to lock again.
@MainActor @Suite(.serialized) struct AskKeepAwake {
    /// Waits up to 5 seconds for `done`.
    private func wait(until done: () -> Bool) async {
        for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func theScreenMayLockAgainWhenAskGoesMidAnswer() async throws {
        // A question held at the thinking row, as in the Debug demo.
        UserDefaults.standard.set(true, forKey: "demoThinking")
        defer { UserDefaults.standard.removeObject(forKey: "demoThinking"); UIApplication.shared.isIdleTimerDisabled = false }
        let database = try SedgeDatabase()
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        // A new id is a new Ask screen, as when MainView is rebuilt for other data.
        func ask(_ id: Int) -> UIViewController {
            UIHostingController(rootView: NavigationStack {
                AskView(database: database, question: .constant(""), reopened: .constant(false))
            }.id(id))
        }
        window.rootViewController = ask(1)
        window.makeKeyAndVisible()
        await wait { UIApplication.shared.isIdleTimerDisabled }
        #expect(UIApplication.shared.isIdleTimerDisabled == true, "the first screen never reached thinking")
        UserDefaults.standard.removeObject(forKey: "demoThinking")
        window.rootViewController = ask(2)
        await wait { !UIApplication.shared.isIdleTimerDisabled }
        window.isHidden = true
        #expect(UIApplication.shared.isIdleTimerDisabled == false)
    }
}
