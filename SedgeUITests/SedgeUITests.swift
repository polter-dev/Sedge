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

    /// Asks Maya's Netflix question end to end, through the real cloud model.
    /// Needs a key: run with `TEST_RUNNER_ANTHROPIC_API_KEY=... xcodebuild test`, which
    /// hands it to this test (never stored in the repo). Skipped without one.
    @MainActor
    func testAskNetflixAsMaya() throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            throw XCTSkip("No ANTHROPIC_API_KEY for the test runner")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launchEnvironment["ANTHROPIC_API_KEY"] = key
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText("How much did I spend at Netflix this year?")
        app.collectionViews.buttons["Ask"].tap()

        // The answer can take a while: the model thinks and calls tools first.
        let answer = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '100.44'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 180), "No answer with 100.44")

        app.buttons["Show work"].tap()
        // The tool's reply lists Maya's Netflix rows by store name.
        let rows = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '\"store\":\"Netflix\"'")).firstMatch
        XCTAssertTrue(rows.waitForExistence(timeout: 5), "No tool rows under Show work")
        add(XCTAttachment(screenshot: app.screenshot()))    }

    /// An unclear question asks once; after an answer and a restart, the same question
    /// doesn't ask again. Real cloud model, so it needs a key like the Netflix test.
    @MainActor
    func testClarifyingQuestionAsksOnlyOnce() throws {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            throw XCTSkip("No ANTHROPIC_API_KEY for the test runner")
        }
        let question = ProcessInfo.processInfo.environment["SEDGE_CLARIFY_QUESTION"] ?? "How much do I spend on food in a month?"
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launchEnvironment["ANTHROPIC_API_KEY"] = key

        /// Types the question on the Ask tab and taps Ask.
        func ask() {
            app.tabBars.buttons["Ask"].tap()
            let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
            field.tap()
            field.typeText(question)
            app.collectionViews.buttons["Ask"].tap()
        }
        /// A named screenshot, kept in the test results even when the test passes.
        func snapshot(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }

        app.launch()
        app.tabBars.buttons["Ask"].tap()
        app.buttons["Reset saved questions"].tap() // start from nothing remembered
        ask()
        let card = app.staticTexts["clarify-question"]
        XCTAssertTrue(card.waitForExistence(timeout: 180), "The model didn't ask")
        snapshot("card")
        // The first quick reply under the question.
        let options = app.collectionViews.buttons.allElementsBoundByIndex.filter { !["Ask", "Skip", "Reset saved questions"].contains($0.label) }
        options[0].tap()
        XCTAssertTrue(app.buttons["Show work"].waitForExistence(timeout: 180), "No answer after the reply")
        snapshot("answered")

        // Restart: the same file opens again, so the saved answer is still there.
        app.terminate()
        app.launch()
        ask()
        // A card would pause the model, and the answer would never come.
        XCTAssertTrue(app.buttons["Show work"].waitForExistence(timeout: 180), "No answer after the restart")
        XCTAssertFalse(card.exists, "Asked again after the restart")
        app.buttons["Show work"].tap()
        snapshot("after-restart")
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
            app.collectionViews.firstMatch.swipeDown() // hides the keyboard
            attachScreenshot(app, "\(persona) what if")

            app.tabBars.buttons["About you"].tap()
            let evidence = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Based on'")).firstMatch
            XCTAssertTrue(evidence.waitForExistence(timeout: 10))
            attachScreenshot(app, "\(persona) profile")
        }
    }

    /// Saved answers with the scripted model (no network, no paid model): an answer made from a
    /// saved reply says what it assumed; changing that reply in the menu changes the next answer,
    /// and removing it makes the next question ask again. A profile correction shows in the
    /// menu too, and is removed at the end so Maya's saved file stays as it was.
    @MainActor
    func testSavedAnswersMenuWithScriptedModel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-scriptedModel", "YES"]
        app.launch()

        // A correction, so the menu shows both kinds of entry: saving a fact unchanged still makes one.
        app.tabBars.buttons["About you"].tap()
        let fact = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Based on'")).firstMatch
        XCTAssertTrue(fact.waitForExistence(timeout: 10))
        fact.tap()
        app.buttons["Save"].tap()

        app.tabBars.buttons["Ask"].tap()
        app.buttons["Reset saved questions"].tap() // start from nothing remembered
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText("How much do I spend on food?")
        let ask = app.collectionViews.buttons["Ask"]
        let card = app.staticTexts["clarify-question"]
        let assumed = app.buttons["assumed-line"]
        /// The scripted answer, which repeats the reply ask_user got back.
        func answer(_ reply: String) -> XCUIElement {
            app.staticTexts["Groceries count as food: \(reply)."]
        }

        // First time: the person is asked, so nothing is assumed.
        ask.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The scripted model didn't ask")
        app.buttons["Yes, groceries too"].tap()
        XCTAssertTrue(answer("Yes, groceries too").waitForExistence(timeout: 10))
        XCTAssertFalse(assumed.exists)

        // Second time: answered from the saved reply, and the answer says so.
        ask.tap()
        XCTAssertTrue(assumed.waitForExistence(timeout: 10), "No assumed line")
        XCTAssertFalse(card.exists, "Asked again despite the saved answer")
        XCTAssertTrue(assumed.label.contains("Yes, groceries too"))
        attachScreenshot(app, "saved-answers-assumed-line")

        // The line opens that entry in the menu, ready to change.
        assumed.tap()
        let alert = app.alerts["Change answer"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "The entry didn't open")
        let reply = alert.textFields.firstMatch
        reply.tap()
        reply.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "No, eating out only")
        alert.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["No, eating out only"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Questions about income"].exists, "The correction isn't in the menu")
        attachScreenshot(app, "saved-answers-menu")
        app.navigationBars["Saved answers"].buttons.element(boundBy: 0).tap() // back to Ask

        // The next ask uses the changed reply.
        ask.tap()
        XCTAssertTrue(answer("No, eating out only").waitForExistence(timeout: 10), "The changed answer wasn't used")

        // Remove both entries; the question is then asked again.
        app.buttons["Saved answers"].tap()
        for entry in ["Should food include groceries?", "Questions about income"] {
            let row = app.staticTexts[entry]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.swipeLeft()
            app.buttons["Remove"].tap()
            XCTAssertFalse(row.waitForExistence(timeout: 2), "\(entry) wasn't removed")
        }
        app.navigationBars["Saved answers"].buttons.element(boundBy: 0).tap()
        ask.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Not asked again after removing the answer")
        app.buttons["Skip"].tap() // a skipped question isn't saved
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
