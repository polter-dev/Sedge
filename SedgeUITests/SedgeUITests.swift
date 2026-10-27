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

    /// Opens the spending, what-if and profile screens for every sample person and checks each
    /// shows its data, with a screenshot of each. Nothing is corrected, so the saved files stay as they were.
    @MainActor
    func testNewScreensForEveryPersona() throws {
        for persona in ["maya", "daniel", "jordan", "elena"] {
            let app = XCUIApplication()
            app.launchArguments = ["-persona", persona]
            app.launch()

            app.tabBars.buttons["Trends"].tap()
            XCTAssertTrue(app.switches["Include money moved between my accounts"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["By category"].exists)
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

    /// The app reopens on the last chosen person, and with no quickstart server the bank
    /// screen says so and leads back to a sample person. Launched without `-persona`, because
    /// a launch argument would win over the saved choice. Needs the quickstart server off.
    /// `-emptyBank` uses a bank file that is never synced, so a bank synced earlier on this
    /// simulator doesn't hide the connect screen. Ends on Maya.
    @MainActor
    func testOpensLastChoiceAndBankServerMessage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-emptyBank", "YES"]
        app.launch()
        // The data picker opens from the Accounts tab.
        let accounts = app.tabBars.buttons["Accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 10))
        accounts.tap()
        let changeData = app.navigationBars.buttons["Change data"]
        XCTAssertTrue(changeData.waitForExistence(timeout: 10))
        changeData.tap()
        XCTAssertTrue(app.staticTexts["Not financial advice. Demo data is made up."].waitForExistence(timeout: 5))
        attachScreenshot(app, "demo-picker")
        app.buttons["Daniel"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Daniel"].waitForExistence(timeout: 10))

        // Quitting and opening again lands straight on Daniel, with no picker in between.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars.staticTexts["Daniel"].waitForExistence(timeout: 10), "Didn't reopen on Daniel")
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
        XCTAssertTrue(app.staticTexts["By category"].waitForExistence(timeout: 10))
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
