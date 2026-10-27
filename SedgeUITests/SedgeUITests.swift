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

            app.tabBars.buttons["Spending"].tap()
            XCTAssertTrue(app.switches["Include money moved between my accounts"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["By category"].exists)
            XCTAssertFalse(app.staticTexts["No spending yet"].exists)
            attachScreenshot(app, "\(persona) spending")

            app.tabBars.buttons["What if"].tap()
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

            app.tabBars.buttons["About you"].tap()
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
        app.tabBars.buttons["About you"].tap()
        let fact = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Based on'")).firstMatch
        XCTAssertTrue(fact.waitForExistence(timeout: 10))
        fact.tap()
        app.buttons["Save"].tap()

        app.tabBars.buttons["Ask"].tap()
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

        app.tabBars.buttons["Ask"].tap()
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

        app.navigationBars.buttons["Change data"].tap()
        app.buttons["Connect bank"].tap()
        XCTAssertTrue(app.staticTexts["Bank server not running"].waitForExistence(timeout: 15))
        attachScreenshot(app, "demo-bank-server-not-running")
        app.buttons["Use a sample person"].tap()
        app.buttons["Maya"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Maya"].waitForExistence(timeout: 10))

        // One screenshot of each main screen, for the demo notes.
        for tab in ["Transactions", "Ask", "Spending", "What if", "About you"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.navigationBars.staticTexts["Maya"].waitForExistence(timeout: 10))
            attachScreenshot(app, "demo-\(tab.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
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
