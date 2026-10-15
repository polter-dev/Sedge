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
