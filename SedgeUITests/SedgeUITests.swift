//
//  SedgeUITests.swift
//  SedgeUITests
//
//  Created by Marcus Ruth on 9/28/26.
//

import XCTest

final class SedgeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    /// No model is wired in, so asking says so plainly instead of answering.
    @MainActor
    func testAskSaysNotConnected() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText("How much did I spend at Netflix this year?")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["The assistant isn't connected yet."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["You · How much did I spend at Netflix this year?"].exists)
        // Without the sample, nothing on screen is demo content.
        XCTAssertTrue(app.staticTexts["Local analysis"].exists)
        attachScreenshot(app, "ask-not-connected")
    }

    /// The Debug sample conversation shows the breakdown card, the answer and the quick check,
    /// and a quick-check tap is saved like any other answer. It is removed again at the end,
    /// so Maya's saved file stays as it was.
    @MainActor
    func testSampleChatSavesTheQuickCheck() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-sampleChat", "YES"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(app.staticTexts["Food & dining"].waitForExistence(timeout: 10), "No breakdown card")
        XCTAssertTrue(app.staticTexts["You · Have I been overspending on food?"].exists)
        let answer = app.staticTexts.containing(NSPredicate(format: "label ENDSWITH 'accounts for most of the difference.'")).firstMatch
        XCTAssertTrue(answer.exists, "No answer")
        XCTAssertTrue(app.staticTexts["A quick check"].exists, "No quick check")
        XCTAssertTrue(app.staticTexts["Local analysis · demo state"].exists)
        attachScreenshot(app, "ask-sample")
        // The quick check's buttons sit below the fold on a phone, so scroll to show them too.
        app.scrollViews.firstMatch.swipeUp()
        attachScreenshot(app, "ask-sample-quick-check")

        app.buttons["Yes, mine"].tap()
        let saved = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Saved: Yes, mine'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "The tap wasn't saved")

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Saved answers"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Was this'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The quick check isn't in Saved answers")
        XCTAssertTrue(app.staticTexts["Yes, mine"].exists)
        attachScreenshot(app, "ask-sample-saved")
        row.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 2), "The saved answer wasn't removed")
    }

    /// The sample shows the same quick check on every launch, so a later tap must replace the
    /// answer saved earlier. The saved answer is removed before asserting, so Maya's file stays as it was.
    @MainActor
    func testSecondLaunchTapNoIsSaved() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-sampleChat", "YES"]
        var shown = "(none)", firstSaved = false, savedAnswersHasNo = false

        app.launch()
        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(app.staticTexts["A quick check"].waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeUp()
        app.buttons["Yes, mine"].tap()
        firstSaved = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Saved: Yes, mine'")).firstMatch.waitForExistence(timeout: 5)
        app.terminate()

        app.launch()
        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(app.staticTexts["A quick check"].waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeUp()
        app.buttons["No"].tap()
        let any = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Saved:' OR label BEGINSWITH 'Not saved'")).firstMatch
        _ = any.waitForExistence(timeout: 5)
        shown = any.exists ? any.label : "(none)"

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Saved answers"].tap()
        let row = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Was this'")).firstMatch
        if row.waitForExistence(timeout: 5) {
            savedAnswersHasNo = app.staticTexts["No"].exists
            row.swipeLeft()
            app.buttons["Remove"].tap()
        }
        XCTAssertTrue(firstSaved, "first launch didn't save Yes, mine")
        XCTAssertTrue(shown.hasPrefix("Saved: No"), "Label after tapping No was: \(shown)")
        XCTAssertTrue(savedAnswersHasNo, "Saved answers does not show No")
    }

    /// Opens the spending, cash-flow and profile screens for every sample person and checks each
    /// shows its data, with a screenshot of each. Nothing is corrected, so the saved files stay as they were.
    @MainActor
    func testNewScreensForEveryPersona() throws {
        for persona in ["maya", "daniel", "jordan", "elena"] {
            let app = XCUIApplication()
            app.launchArguments = ["-persona", persona]
            app.launch()

            app.tabBars.buttons["Trends"].tap()
            XCTAssertTrue(app.staticTexts["Your patterns"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["No spending yet"].exists)
            attachScreenshot(app, "\(persona) spending")

            app.navigationBars.buttons["Cash flow"].tap()
            let field = app.textFields["Extra purchase in dollars"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            field.typeText("400")
            app.buttons["Add purchase"].tap()
            XCTAssertTrue(app.switches["purchase"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["With changes"].waitForExistence(timeout: 5))
            // Scrolling hides the number pad, which would otherwise cover the tab bar. A simulator
            // with keyboard minimizing on (a used simulator that has seen a hardware keyboard) never
            // shows the pad: it waits just below the screen, still in the element tree. So the check
            // is that no pad overlaps the tabs, not that no keyboard exists.
            app.scrollViews.firstMatch.swipeDown()
            let tabs = app.tabBars.firstMatch.frame
            let tabsClear = NSPredicate { _, _ in
                let pad = app.keyboards.firstMatch
                return !pad.exists || !pad.frame.intersects(tabs)
            }
            let waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: tabsClear, object: nil)], timeout: 5)
            XCTAssertEqual(waited, .completed, "The number pad is still covering the tabs")
            attachScreenshot(app, "\(persona) cash flow")

            app.tabBars.buttons["Accounts"].tap()
            app.buttons["About you"].tap()
            // Each tile is one button that reads everything it shows, starting with its kind.
            let income = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Income,'")).firstMatch
            XCTAssertTrue(income.waitForExistence(timeout: 10))
            attachScreenshot(app, "\(persona) profile")
        }
    }

    /// A profile correction shows in the Saved answers menu, and swiping removes it, so Maya's
    /// saved file stays as it was.
    @MainActor
    func testSavedAnswersMenuShowsAndRemovesACorrection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        // Saving a fact unchanged still makes a correction.
        app.tabBars.buttons["Accounts"].tap()
        app.buttons["About you"].tap()
        // Each tile is one button that reads its whole fact, starting with its kind.
        let fact = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Income,'")).firstMatch
        XCTAssertTrue(fact.waitForExistence(timeout: 10))
        fact.tap()
        app.buttons["Save"].tap()
        // The corrected tile keeps its amount and its next payday.
        let corrected = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Income, $520.00' AND label ENDSWITH 'Next Jul 3'")).firstMatch
        XCTAssertTrue(corrected.waitForExistence(timeout: 5), "The income tile changed after saving it unchanged")
        attachScreenshot(app, "about-you-corrected")

        // Back to the Accounts list, where the menu is.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Saved answers"].tap()
        let row = app.staticTexts["Questions about income"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The correction isn't in the menu")
        attachScreenshot(app, "saved-answers-menu")
        row.swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 2), "The correction wasn't removed")
    }

    /// Reset asks first: Cancel leaves the saved answers alone, and only Delete clears them.
    @MainActor
    func testResetAsksBeforeDeleting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let reset = app.buttons["Reset saved questions"]
        let cleared = app.staticTexts["Saved answers cleared."]

        reset.tap()
        let question = app.alerts["Delete all saved answers?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Reset didn't ask first")
        XCTAssertTrue(question.staticTexts["This can't be undone."].exists)
        attachScreenshot(app, "reset-confirm")
        question.buttons["Cancel"].tap()
        XCTAssertFalse(cleared.waitForExistence(timeout: 2), "Cancel cleared the saved answers")

        reset.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.buttons["Delete"].tap()
        XCTAssertTrue(cleared.waitForExistence(timeout: 5), "Delete didn't clear the saved answers")
    }

    /// A fresh install shows Welcome, Explore sample data opens the picker, and after picking the
    /// app reopens on that person with no Welcome. With no quickstart server the bank screen says
    /// so and leads back to a sample person. `-firstLaunch` forgets the saved choice, as on a fresh
    /// install; the relaunch leaves it off, and never passes `-persona`, because a launch argument
    /// would win over the saved choice. Needs the quickstart server off. `-emptyBank` uses a bank
    /// file that is never synced, so a bank synced earlier on this simulator doesn't hide the
    /// connect screen. Ends on Maya.
    @MainActor
    func testFirstLaunchThenOpensLastChoiceAndBankServerMessage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-emptyBank", "YES", "-firstLaunch", "YES"]
        app.launch()
        // The headline has a line break in it, so it is found by its start.
        let welcome = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'A clearer view'")).firstMatch
        XCTAssertTrue(welcome.waitForExistence(timeout: 10), "No Welcome on first launch")
        XCTAssertTrue(app.staticTexts["A preview of what you can explore"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        attachScreenshot(app, "welcome")
        app.buttons["Explore sample data"].tap()
        XCTAssertTrue(app.staticTexts["Not financial advice. Demo data is made up."].waitForExistence(timeout: 5))
        attachScreenshot(app, "demo-picker")
        app.buttons["Daniel"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Daniel"].waitForExistence(timeout: 10))

        // Quitting and opening again lands straight on Daniel, with no Welcome or picker in between.
        app.terminate()
        app.launchArguments = ["-emptyBank", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars.staticTexts["Daniel"].waitForExistence(timeout: 10), "Didn't reopen on Daniel")
        XCTAssertFalse(welcome.exists)
        XCTAssertFalse(app.staticTexts["Sample people"].exists)

        // Picking other data keeps the Accounts tab open, so the bank's transactions are one tap away.
        app.tabBars.buttons["Accounts"].tap()
        app.navigationBars.buttons["Change data"].tap()
        app.buttons["Connect bank"].tap()
        app.buttons["Transactions"].tap()
        XCTAssertTrue(app.staticTexts["Bank server not running"].waitForExistence(timeout: 15))
        attachScreenshot(app, "demo-bank-server-not-running")
        app.buttons["Use a sample person"].tap()
        app.buttons["Maya"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Maya"].waitForExistence(timeout: 10))
    }

    /// On Welcome, Connect with Plaid opens the bank screen, which with no quickstart server says
    /// so and leads to the sample people. Needs the quickstart server off. Ends on Maya.
    @MainActor
    func testWelcomeConnectWithPlaidOpensBankFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-emptyBank", "YES", "-firstLaunch", "YES"]
        app.launch()
        let connect = app.buttons["Connect with Plaid"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.staticTexts["Bank server not running"].waitForExistence(timeout: 15))
        attachScreenshot(app, "welcome-bank-server-not-running")
        app.buttons["Use a sample person"].tap()
        app.buttons["Maya"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Maya"].waitForExistence(timeout: 10))
    }

    /// The app has exactly three tabs, Ask, Trends and Accounts, and every screen from before
    /// the tabs were folded together is still reached through them, with a screenshot of each
    /// screen. For dark screenshots, run it after `xcrun simctl ui <device> appearance dark`.
    /// Nothing is changed, so Maya's saved file stays as it was.
    @MainActor
    func testThreeTabsReachEveryScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Ask"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["Ask", "Trends", "Accounts"])

        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10) || app.textFields.firstMatch.exists)
        attachScreenshot(app, "tab-ask")

        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(app.staticTexts["Your patterns"].waitForExistence(timeout: 10))
        attachScreenshot(app, "tab-trends-spending")
        app.navigationBars.buttons["Cash flow"].tap()
        XCTAssertTrue(app.textFields["Extra purchase in dollars"].waitForExistence(timeout: 10))
        attachScreenshot(app, "trends-cash-flow")

        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.buttons["Transactions"].waitForExistence(timeout: 10))
        attachScreenshot(app, "tab-accounts")

        // Each screen below opens from the Accounts list; the first nav bar button goes back to it.
        app.buttons["Transactions"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Transactions"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No transactions"].exists)
        attachScreenshot(app, "accounts-transactions")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["About you"].tap()
        let income = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Income,'")).firstMatch
        XCTAssertTrue(income.waitForExistence(timeout: 10))
        attachScreenshot(app, "accounts-about-you")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["Saved answers"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Saved answers"].waitForExistence(timeout: 10))
        attachScreenshot(app, "accounts-saved-answers")
        app.navigationBars.buttons.firstMatch.tap()

        app.navigationBars.buttons["Change data"].tap()
        XCTAssertTrue(app.staticTexts["Sample people"].waitForExistence(timeout: 5))
        attachScreenshot(app, "accounts-change-data")
        app.buttons["Cancel"].tap()
    }

    /// Tapping a store in Maya's spending graph shows its latest transaction, which opens the
    /// transaction; "Ask about a tradeoff" goes to the Ask tab. The screenshot is the screen
    /// in light, or dark after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testTappingAStoreShowsItsLatestTransaction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let store = app.buttons.matching(identifier: "store").firstMatch
        XCTAssertTrue(store.waitForExistence(timeout: 10))
        // The node reads "Store name, $123"; the latest transaction's row starts with the same name.
        let name = String(store.label.split(separator: ",")[0])
        let latest = app.buttons["latest"]
        XCTAssertFalse(latest.exists)
        store.tap()
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(latest.label.hasPrefix(name), "\(latest.label) isn't from \(name)")
        XCTAssertTrue(latest.label.contains("Latest transaction"))
        attachScreenshot(app, "spending-graph")

        latest.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Transaction"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["Ask about a tradeoff →"].tap()
        XCTAssertTrue(app.tabBars.buttons["Ask"].isSelected)
    }

    /// Tapping May's bar on Maya's Spending screen shows May: its total, the change line, the
    /// graph's heading and a May latest transaction. "This month" brings June back. The
    /// screenshots are the screen in light, or dark after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testTappingAMonthShowsItsSpending() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let may = app.otherElements["May"]
        XCTAssertTrue(may.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connected spending · June"].exists)
        XCTAssertFalse(app.buttons["This month"].exists)
        attachScreenshot(app, "month-default")

        may.tap()
        let thisMonth = app.buttons["This month"]
        XCTAssertTrue(thisMonth.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connected spending · May"].waitForExistence(timeout: 5))
        // The big total is May's bar, and the line beside the title starts with May.
        let mayTotal = try XCTUnwrap(may.value as? String)
        XCTAssertGreaterThan(app.staticTexts.matching(NSPredicate(format: "label == %@", mayTotal)).count, 0)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'May · '")).firstMatch.exists)
        let store = app.buttons.matching(identifier: "store").firstMatch
        XCTAssertTrue(store.waitForExistence(timeout: 5))
        store.tap()
        let latest = app.buttons["latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(latest.label.contains("May "), "\(latest.label) isn't from May")
        attachScreenshot(app, "month-picked")

        thisMonth.tap()
        XCTAssertTrue(app.staticTexts["Connected spending · June"].waitForExistence(timeout: 5))
        XCTAssertFalse(thisMonth.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'June so far'")).firstMatch.exists)
    }

    /// On Maya's cash flow, switching a scenario on moves "Projected" by exactly its amount, and
    /// switching it off puts it back: a $400 purchase, then cancelling subscriptions by the saving
    /// the simulator works out for that row. For dark screenshots, run it after
    /// `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testCashFlowScenariosMoveProjectedByTheirAmount() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        app.navigationBars.buttons["Cash flow"].tap()
        let projected = app.staticTexts["projected"]
        XCTAssertTrue(projected.waitForExistence(timeout: 10))
        attachScreenshot(app, "cash-flow")
        let plan = try dollars(projected.label)

        // A $400 purchase starts switched on.
        let field = app.textFields["Extra purchase in dollars"]
        field.tap()
        field.typeText("400")
        app.buttons["Add purchase"].tap()
        let purchase = app.switches["purchase"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeDown()
        try waitForDollars(projected, plan - 400)
        attachScreenshot(app, "cash-flow-with-purchase")
        flip(purchase, in: app)
        try waitForDollars(projected, plan)

        // The row says what cancelling saves, e.g. "Save $17.99 · before Jul 3".
        let cancel = app.switches["cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let saved = NSPredicate(format: "label CONTAINS 'Save $'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: cancel)], timeout: 5), .completed)
        let saving = try dollars(String(cancel.label.components(separatedBy: "Save ")[1].split(separator: " ")[0]))
        XCTAssertGreaterThan(saving, 0)
        flip(cancel, in: app)
        try waitForDollars(projected, plan + saving)
        flip(cancel, in: app)
        try waitForDollars(projected, plan)

        // Over 90 days the card payments come from checking, so the shaded range widens.
        app.scrollViews.firstMatch.swipeDown()
        app.buttons["90 days"].tap()
        XCTAssertTrue(app.staticTexts["Projected Sep 28"].waitForExistence(timeout: 5))
        attachScreenshot(app, "cash-flow-90-days")
    }

    /// The purchase entry and the bill amount are laid out by hand (no Form rows), so each
    /// needs its own 44 pt tall target.
    @MainActor
    func testCashFlowEntryTargetsAreAtLeast44Points() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Trends"].tap()
        app.navigationBars.buttons["Cash flow"].tap()
        XCTAssertTrue(app.staticTexts["projected"].waitForExistence(timeout: 10))

        // Switch "Change a bill" on to show its amount field.
        flip(app.switches["bill"], in: app)
        let billAmount = app.textFields["Change per bill in dollars, e.g. 200 or -50"]
        XCTAssertTrue(billAmount.waitForExistence(timeout: 5))

        for (name, element) in [("Add purchase", app.buttons["Add purchase"]),
                                ("Extra purchase field", app.textFields["Extra purchase in dollars"]),
                                ("Bill amount field", billAmount)] {
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) is \(element.frame.height) pt tall")
        }
    }

    /// A tap anywhere in the 44 pt purchase and bill fields focuses them, not only in the middle.
    @MainActor
    func testCashFlowFieldsFocusFromTheirWholeHeight() throws {
        for name in ["Extra purchase in dollars", "Change per bill in dollars, e.g. 200 or -50"] {
            let app = XCUIApplication()
            app.launchArguments = ["-persona", "maya"]
            app.launch()
            app.tabBars.buttons["Trends"].tap()
            app.navigationBars.buttons["Cash flow"].tap()
            XCTAssertTrue(app.staticTexts["projected"].waitForExistence(timeout: 10))
            if name.hasPrefix("Change") { flip(app.switches["bill"], in: app) }
            let field = app.textFields[name]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            for _ in 0..<4 where field.frame.maxY > app.tabBars.firstMatch.frame.minY {
                app.scrollViews.firstMatch.swipeUp()
            }
            // 6 pt below the top: inside the 44 pt target, outside the old 22 pt text.
            field.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: field.frame.width / 2, dy: 6)).tap()
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 3), .completed, "\(name): a tap near the top did not focus it")
            app.terminate()
        }
    }

    /// Scrolls a switch clear of the tab bar, then taps its knob: a tap on the label of a SwiftUI
    /// toggle outside a list doesn't flip it, and a tap by position doesn't scroll by itself.
    @MainActor
    private func flip(_ toggle: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where toggle.frame.maxY > app.tabBars.firstMatch.frame.minY {
            app.scrollViews.firstMatch.swipeUp()
        }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// Dollars from text such as "$2,420.15" or "-$12.00".
    private func dollars(_ text: String) throws -> Double {
        let number = text.filter { "0123456789.-".contains($0) }
        return try XCTUnwrap(Double(number), "Not an amount: \(text)")
    }

    /// Waits for an amount to show exactly `expected`, to the cent, since the projection reloads after a switch.
    @MainActor
    private func waitForDollars(_ element: XCUIElement, _ expected: Double) throws {
        let shown = NSPredicate { _, _ in
            guard let value = try? self.dollars(element.label) else { return false }
            return abs(value - expected) < 0.005
        }
        let waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 5)
        XCTAssertEqual(waited, .completed, "Projected shows \(element.label), expected \(expected)")
    }

    /// Moving Maya's Jun 18 Corner Cafe charge ($10.40) from Dining to Groceries moves its amount
    /// between those categories' June bars on the Spending screen, and moving it back restores
    /// them, so Maya's saved file ends as it was. Also checks Sedge's context for that charge: her
    /// three visits before it (Corner Cafe, TST* Corner Cafe and Corner Cafe Restaurant are one
    /// store) were $9.11, $8.81 and $9.29.
    @MainActor
    func testChangingCategoryMovesSpending() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        let before = (dining: try spent(app, "Dining"), groceries: try spent(app, "Groceries"))

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Transactions"].tap()
        let row = app.buttons["Corner Cafe, CORNER CAFE, $10.40"]
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["Higher than your last three visits."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Those were $8.81–$9.29."].exists)
        XCTAssertTrue(app.staticTexts["This is a spending observation, not a fraud determination."].exists)
        attachScreenshot(app, "transaction-detail")

        try pickCategory(app, "Groceries")
        attachScreenshot(app, "transaction-detail-groceries")
        let moved = (dining: try spent(app, "Dining"), groceries: try spent(app, "Groceries"))
        // The bars show whole dollars, so $10.40 moves by 10 or 11 after rounding.
        XCTAssertTrue((10...11).contains(before.dining - moved.dining), "Dining went from \(before.dining) to \(moved.dining)")
        XCTAssertTrue((10...11).contains(moved.groceries - before.groceries), "Groceries went from \(before.groceries) to \(moved.groceries)")

        // Back to the store's own category, which clears the answer.
        app.tabBars.buttons["Accounts"].tap()
        try pickCategory(app, "Dining")
        XCTAssertEqual(try spent(app, "Dining"), before.dining)
        XCTAssertEqual(try spent(app, "Groceries"), before.groceries)
    }

    /// Answering "Is this account yours?" from Your accounts shows the answer on that account,
    /// and Later leaves it unanswered. Clears the answers at the end, so Maya's saved file ends as it was.
    @MainActor
    func testAccountQuickCheckShowsTheAnswer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Your accounts"].tap()

        // Shared, then Yes, mine, so each answer is seen to change what the account shows.
        let checking = app.buttons["Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        checking.tap()
        XCTAssertTrue(app.staticTexts["Is this account yours?"].waitForExistence(timeout: 5))
        attachScreenshot(app, "account-quick-check")
        app.buttons["Shared"].tap()
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        XCTAssertEqual(checking.value as? String, "Shared")
        checking.tap()
        app.buttons["Yes, mine"].tap()
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        XCTAssertEqual(checking.value as? String, "Yours")

        let card = app.buttons["Credit Card"]
        card.tap()
        app.buttons["Later"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.value as? String, "Later")
        attachScreenshot(app, "accounts-with-answers")

        // The app has no way to take an owner answer back, so a debug launch argument clears them.
        app.terminate()
        app.launchArguments = ["-persona", "maya", "-clearOwnerAnswers", "YES"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Your accounts"].tap()
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        XCTAssertEqual(checking.value as? String, "Later")
    }

    /// A name typed in the account check shows on Your accounts in place of the bank's name, and
    /// clearing the field brings the bank's name back, so Maya's saved file ends as it was.
    @MainActor
    func testNamingAnAccountShowsTheNameOnYourAccounts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Your accounts"].tap()

        let checking = app.buttons["Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        checking.tap()
        let field = app.textFields["Account name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Everyday")
        attachScreenshot(app, "account-check-named")
        app.buttons["Later"].tap()

        let named = app.buttons["Everyday"]
        XCTAssertTrue(named.waitForExistence(timeout: 5))
        XCTAssertFalse(checking.exists)
        attachScreenshot(app, "your-accounts-named")

        // Clear the name: the row goes back to the bank's name.
        named.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["Clear name"].tap()
        app.buttons["Later"].tap()
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        XCTAssertFalse(named.exists)
    }

    /// After a bank connection, each unanswered account is asked about once, one after another.
    /// The launch argument stands in for a finished Plaid sync, so no quickstart server is needed.
    /// Later answers nothing, so Maya's saved file stays as it was.
    @MainActor
    func testQuickCheckAfterConnectingAsksEachUnansweredAccountOnce() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-checkAccountsAfterConnecting", "YES"]
        app.launch()

        let question = app.staticTexts["Is this account yours?"]
        var asked: [String] = []
        while question.waitForExistence(timeout: 5) {
            let name = app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Checking", "Credit Card"])).firstMatch.label
            asked.append(name)
            app.buttons["Later"].tap()
            // Wait for this sheet to go before looking for the next one.
            XCTAssertTrue(app.staticTexts[name].waitForNonExistence(timeout: 5))
            if asked.count > 2 { break }
        }
        // Maya has two accounts; one may already be answered by another test on this simulator.
        XCTAssertFalse(asked.isEmpty)
        XCTAssertEqual(asked.count, Set(asked).count, "An account was asked about twice")
        XCTAssertTrue(app.tabBars.buttons["Ask"].isHittable)
    }

    /// The spending note's × hides it on every transaction, not just the one it was tapped on,
    /// and the Accounts tab's "Show the spending note again" row brings it back. The note ends
    /// shown, as it started. For dark screenshots, run it after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testSpendingNoteHidesEverywhereAndComesBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let showAgain = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show the spending note again'")).firstMatch
        // A run stopped halfway may have left the note hidden; start with it shown.
        if showAgain.waitForExistence(timeout: 3) { showAgain.tap() }

        let corner = "Corner Cafe, CORNER CAFE, -$10.40"
        let note = app.staticTexts["This is a spending observation, not a fraud determination."]
        let undoLine = app.staticTexts["Spending note hidden on every transaction."]
        openTransaction(app, corner)
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        attachScreenshot(app, "note-with-dismiss")
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(undoLine.waitForExistence(timeout: 2))
        XCTAssertFalse(note.exists)
        attachScreenshot(app, "note-hidden-undo")
        // The Undo line stays 4 s, then the box collapses.
        XCTAssertTrue(undoLine.waitForNonExistence(timeout: 6))
        XCTAssertFalse(note.exists)
        attachScreenshot(app, "note-collapsed")

        // Another purchase at the same store has Sedge's context too, and no note either.
        app.navigationBars.buttons.firstMatch.tap()
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Corner Cafe, ' AND label != %@", corner)).firstMatch
        for _ in 0..<10 where !(other.exists && other.isHittable) { app.swipeUp() }
        other.tap()
        XCTAssertTrue(app.staticTexts["Sedge’s context"].waitForExistence(timeout: 10))
        XCTAssertFalse(note.exists)

        // Back on the Accounts tab, the row shows the note again and then goes away.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        // At the largest text sizes the row is below the fold.
        for _ in 0..<10 where !(showAgain.exists && showAgain.isHittable) { app.swipeUp() }
        XCTAssertTrue(showAgain.isHittable)
        attachScreenshot(app, "accounts-show-note-again")
        showAgain.tap()
        XCTAssertTrue(showAgain.waitForNonExistence(timeout: 5))
        openTransaction(app, corner)
        XCTAssertTrue(note.waitForExistence(timeout: 10))
    }

    /// "Does this look familiar?" saves at once and counts down with Undo. Undo before 0 leaves the
    /// answer empty, and waiting past 0 folds the prompt away and keeps the answer. Reopening the
    /// transaction reads the answer back from the database. The answer is undone at the end, so
    /// Maya's saved file ends as it was. For dark screenshots, run it after
    /// `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testFamiliarUndoLeavesItEmptyAndWaitingKeepsIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let corner = "Corner Cafe, CORNER CAFE, -$10.40"
        let yes = app.buttons["Yes"], notSure = app.buttons["Not sure"]
        /// Goes back to the transactions list and opens the same transaction again, which reloads it.
        func reopen() {
            app.navigationBars.buttons.firstMatch.tap()
            app.buttons[corner].tap()
            XCTAssertTrue(yes.waitForExistence(timeout: 10))
        }
        openTransaction(app, corner)
        XCTAssertTrue(yes.waitForExistence(timeout: 10))
        XCTAssertFalse(yes.isSelected)
        XCTAssertFalse(notSure.isSelected)

        // Undo before 0: the buttons come back and nothing is saved.
        yes.tap()
        XCTAssertTrue(app.staticTexts["Saved · Yes"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Closing in '")).firstMatch.exists)
        attachScreenshot(app, "familiar-countdown")
        app.buttons["Undo"].tap()
        XCTAssertTrue(yes.waitForExistence(timeout: 2))
        XCTAssertFalse(yes.isSelected)
        reopen()
        XCTAssertFalse(yes.isSelected)
        XCTAssertFalse(notSure.isSelected)

        // Waiting past 0: the whole prompt folds away and the answer stays.
        notSure.tap()
        XCTAssertTrue(app.staticTexts["Saved · Not sure"].waitForExistence(timeout: 2))
        // The ring reaches 0 before the prompt folds away. 0 shows for well under a second and
        // waitForExistence checks only about once a second, so this reads the ring's label in a
        // tight loop until the ring is gone. One snapshot per read, so a fold mid-read can't fail.
        let ring = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Closing in '")).firstMatch
        var seen: Set<String> = []
        let end = Date().addingTimeInterval(7)
        while Date() < end, let label = try? ring.snapshot().label { seen.insert(label) }
        XCTAssertTrue(seen.contains("Closing in 1"), "The ring was never seen at 1; saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Closing in 0"), "The ring never showed 0; saw \(seen.sorted())")
        XCTAssertTrue(app.staticTexts["Does this look familiar?"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(notSure.exists)
        attachScreenshot(app, "familiar-folded")
        reopen()
        XCTAssertTrue(notSure.isSelected)
        XCTAssertFalse(yes.isSelected)
        attachScreenshot(app, "familiar-answered-later")

        // Clean up: answer again, then Undo, which empties it.
        notSure.tap()
        app.buttons["Undo"].tap()
        reopen()
        XCTAssertFalse(notSure.isSelected)
    }

    /// From the Accounts tab, opens the transaction whose row reads `label`.
    @MainActor
    private func openTransaction(_ app: XCUIApplication, _ label: String) {
        app.buttons["Transactions"].tap()
        let row = app.buttons[label]
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
    }

    /// Picks a category on the open transaction screen and checks the screen shows it.
    @MainActor
    private func pickCategory(_ app: XCUIApplication, _ category: String) throws {
        let menu = app.buttons["Category"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons[category].tap()
        XCTAssertTrue(app.buttons["Category"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["Category"].value as? String, category)
    }

    /// One category's June bar on the Spending screen, in whole dollars (Maya's today is Jun 30).
    @MainActor
    private func spent(_ app: XCUIApplication, _ category: String) throws -> Int {
        app.tabBars.buttons["Trends"].tap()
        let chip = app.buttons[category]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.tap()
        XCTAssertTrue(chip.isSelected)
        let june = app.otherElements["June"]
        XCTAssertTrue(june.waitForExistence(timeout: 5))
        let value = try XCTUnwrap(june.value as? String).filter(\.isNumber)
        return try XCTUnwrap(Int(value), "Not a number: \(value)")
    }

    /// Keeps a screenshot in the test results, named for what it shows.
    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// The All months screen opens from Trends with its month chart, its category chart and the
    /// money-moved switch. The switch adds a "Moved between accounts" bar and turning it off
    /// restores the totals. The screenshot is the screen in light, or dark after
    /// `xcrun simctl ui <device> appearance dark`. Nothing is changed in Maya's saved file.
    @MainActor
    func testAllMonthsShowsEveryMonthCategoryAndMoneyMoved() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let link = app.buttons["All months & categories →"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.staticTexts["By month"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["By category"].exists)
        let june = app.otherElements["June 2026"]
        XCTAssertTrue(june.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["January 2026"].exists)
        let dining = app.otherElements["Dining"]
        XCTAssertTrue(dining.exists)
        let before = (june: june.value as? String, dining: dining.value as? String)
        let moved = app.otherElements["Moved between accounts"]
        XCTAssertFalse(moved.exists)
        attachScreenshot(app, "all-months")

        let toggle = app.switches["Include money moved between my accounts"]
        // The inner switch, so the tap lands on the control and not on its label.
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(moved.waitForExistence(timeout: 5))
        // Money moved is its own bar, so the spending ones stay the same.
        XCTAssertEqual(june.value as? String, before.june)
        XCTAssertEqual(dining.value as? String, before.dining)
        attachScreenshot(app, "all-months-with-money-moved")

        toggle.switches.firstMatch.tap()
        XCTAssertTrue(moved.waitForNonExistence(timeout: 5))
        XCTAssertEqual(june.value as? String, before.june)
        XCTAssertEqual(dining.value as? String, before.dining)
    }

    /// Both Trends screens read the data again each time they show: moving Maya's Jun 18 Corner
    /// Cafe charge ($10.40) out of Dining, with the app open and the category chips untouched,
    /// lowers Dining on the All months screen and the June bar on the Spending screen. Moving it
    /// back restores them, so Maya's saved file ends as it was.
    @MainActor
    func testTrendsScreensReloadWhenShown() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let chip = app.buttons["Dining"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertTrue(chip.isSelected)
        let june = app.otherElements["June"]
        let before = try dollars(june)
        app.buttons["All months & categories →"].tap()
        let dining = app.otherElements["Dining"]
        let beforeAll = try dollars(dining)

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Transactions"].tap()
        let row = app.buttons["Corner Cafe, CORNER CAFE, $10.40"]
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        try pickCategory(app, "Groceries")

        // The Trends tab comes back on All months, which was left open.
        app.tabBars.buttons["Trends"].tap()
        let afterAll = try dollars(dining)
        XCTAssertTrue((10...11).contains(beforeAll - afterAll), "All months Dining went from \(beforeAll) to \(afterAll)")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.isSelected)
        let after = try dollars(june)
        XCTAssertTrue((10...11).contains(before - after), "June Dining went from \(before) to \(after)")

        // Back to the store's own category, which clears the answer.
        app.tabBars.buttons["Accounts"].tap()
        try pickCategory(app, "Dining")
        app.tabBars.buttons["Trends"].tap()
        XCTAssertEqual(try dollars(june), before)
    }

    /// Tapping Maya's Groceries chip on Spending selects it and shows Groceries' numbers: the
    /// first 30 days of March to June are $104.73, $100.33, $115.23 and $86.97 (shown in whole
    /// dollars), and June's only grocery store is Value Mart. The screenshot is light, or dark
    /// after `xcrun simctl ui <device> appearance dark`. Nothing is changed in Maya's saved file.
    @MainActor
    func testCategoryChipSwitchesTheChart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let dining = app.buttons["Dining"]
        XCTAssertTrue(dining.waitForExistence(timeout: 10))
        XCTAssertTrue(dining.isSelected)
        let groceries = app.buttons["Groceries"]
        XCTAssertGreaterThanOrEqual(groceries.frame.height, 44 - 0.001)
        groceries.tap()

        XCTAssertTrue(groceries.isSelected)
        XCTAssertFalse(dining.isSelected)
        XCTAssertTrue(app.staticTexts["$87"].waitForExistence(timeout: 5))
        for (month, total) in [("March", "$105"), ("April", "$100"), ("May", "$115"), ("June", "$87")] {
            XCTAssertEqual(app.otherElements[month].value as? String, total, month)
        }
        XCTAssertTrue(app.buttons["Value Mart, $87"].waitForExistence(timeout: 5))
        attachScreenshot(app, "spending-groceries")
    }

    /// Ways to save opens from Spending; a $200 goal lists Daniel's cuts ranked least valued first
    /// (the same list `savingsListsForAHandCheck` prints), and the goal row is a 44 pt target that
    /// focuses from near its top. The screenshot is light, or dark after
    /// `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testWaysToSaveRanksCutsForAGoal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "daniel"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let link = app.buttons["Ways to save →"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        // A row placed at a fractional y reads back as 43.99999…, so allow for rounding.
        XCTAssertGreaterThanOrEqual(link.frame.height, 44 - 0.001)
        link.tap()

        let field = app.textFields["Monthly goal in dollars"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(field.frame.height, 44)
        // 6 pt below the top of the row: inside the 44 pt target, outside the text line.
        field.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: field.frame.width / 2, dy: 6)).tap()
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 3), .completed)
        field.typeText("200")

        // Each rank in turn, scrolling to it: the list only builds the rows in view, and at the
        // largest text sizes it starts below the fold.
        let cuts = app.descendants(matching: .any).matching(identifier: "cut")
        // Netflix is a monthly charge, so its evidence says the low weeks don't judge it (review R2-1).
        let expected = ["1. Netflix, $16.74 a month. Subscriptions; bought in 5 of 25 weeks; once a month at most, so not judged on lowest-balance weeks.",
                        "2. Homegoods, $47.29 a month. Shopping; bought in 8 of 25 weeks; 100% of usual",
                        "3. Amazon, $70.60 a month.", "4. Bean Street Coffee, $10.21 a month.", "5. Corner Cafe, $180.01 a month."]
        for start in expected {
            let cut = cuts.matching(NSPredicate(format: "label BEGINSWITH %@", start)).firstMatch
            for _ in 0..<6 where !cut.waitForExistence(timeout: 2) { app.swipeUp() }
            XCTAssertTrue(cut.exists, "No row starting: \(start)")
        }
        let summary = app.staticTexts["savings-summary"]
        for _ in 0..<6 where !summary.exists { app.swipeUp() }
        XCTAssertTrue(summary.label.hasPrefix("Together $324.85 a month, enough"), summary.label)
        XCTAssertFalse(cuts.matching(NSPredicate(format: "label BEGINSWITH '6. '")).firstMatch.exists)
        for _ in 0..<6 { app.swipeDown() }
        attachScreenshot(app, "ways-to-save")
    }

    /// A chart bar's value, such as "$1,234", in whole dollars.
    @MainActor
    private func dollars(_ bar: XCUIElement) throws -> Int {
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let value = try XCTUnwrap(bar.value as? String).filter(\.isNumber)
        return try XCTUnwrap(Int(value), "Not a number: \(value)")
    }
}
