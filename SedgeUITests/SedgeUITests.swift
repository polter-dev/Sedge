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

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
