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
        app.collectionViews.buttons["Ask"].tap()
        XCTAssertTrue(app.staticTexts["The assistant isn't connected yet."].waitForExistence(timeout: 5))
        attachScreenshot(app, "ask-not-connected")
    }

    /// Opens the spending, what-if and profile screens for every sample person and checks each
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

            app.navigationBars.buttons["What if"].tap()
            let field = app.textFields["Extra purchase in dollars"]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            field.typeText("400")
            XCTAssertTrue(app.staticTexts["With the purchase"].waitForExistence(timeout: 5))
            // Scrolling hides the number pad, which would otherwise cover the tab bar. A simulator
            // with keyboard minimizing on (a used simulator that has seen a hardware keyboard) never
            // shows the pad: it waits just below the screen, still in the element tree. So the check
            // is that no pad overlaps the tabs, not that no keyboard exists.
            app.collectionViews.firstMatch.swipeDown()
            let tabs = app.tabBars.firstMatch.frame
            let tabsClear = NSPredicate { _, _ in
                let pad = app.keyboards.firstMatch
                return !pad.exists || !pad.frame.intersects(tabs)
            }
            let waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: tabsClear, object: nil)], timeout: 5)
            XCTAssertEqual(waited, .completed, "The number pad is still covering the tabs")
            attachScreenshot(app, "\(persona) what if")

            app.tabBars.buttons["Accounts"].tap()
            app.buttons["About you"].tap()
            let evidence = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Based on'")).firstMatch
            XCTAssertTrue(evidence.waitForExistence(timeout: 10))
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
        let fact = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Based on'")).firstMatch
        XCTAssertTrue(fact.waitForExistence(timeout: 10))
        fact.tap()
        app.buttons["Save"].tap()

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
        app.navigationBars.buttons["What if"].tap()
        XCTAssertTrue(app.textFields["Extra purchase in dollars"].waitForExistence(timeout: 10))
        attachScreenshot(app, "trends-what-if")

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
        let evidence = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Based on'")).firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 10))
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
        let row = app.buttons["Corner Cafe, CORNER CAFE, -$10.40"]
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

    /// Answering "Is this account yours?" from the Accounts tab shows the answer on that account,
    /// and Later leaves it unanswered. Clears the answers at the end, so Maya's saved file ends as it was.
    @MainActor
    func testAccountQuickCheckShowsTheAnswer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()

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
        XCTAssertEqual(card.value as? String, "Not answered")
        attachScreenshot(app, "accounts-with-answers")

        // The app has no way to take an owner answer back, so a debug launch argument clears them.
        app.terminate()
        app.launchArguments = ["-persona", "maya", "-clearOwnerAnswers", "YES"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        XCTAssertEqual(checking.value as? String, "Not answered")
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
        let menu = app.buttons["Category"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        if menu.value as? String != category {
            menu.tap()
            app.buttons[category].tap()
        }
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
}
