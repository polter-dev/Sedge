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

    /// No model is wired in, so asking shows the thinking row briefly, then says so plainly
    /// instead of answering.
    @MainActor
    func testAskSaysNotConnected() throws {
        let app = XCUIApplication()
        // Reduce Motion keeps the sprout still. It draws and erases on a loop, and the test waits
        // for the screen to settle after each tap, which would outlast the thinking row.
        // `-slowThinking` holds the row 6 s instead of 1.5 s, so a busy machine can't miss it.
        app.launchArguments = ["-persona", "maya", "-reduceMotion", "YES", "-slowThinking", "YES"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText("How much did I spend at Netflix this year?")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["thinkingRow"].waitForExistence(timeout: 3), "No thinking row")
        XCTAssertTrue(app.staticTexts["The assistant isn't connected yet."].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["thinkingRow"].exists, "The thinking row stayed after the reply")
        XCTAssertTrue(app.staticTexts["You · How much did I spend at Netflix this year?"].exists)
        attachScreenshot(app, "ask-not-connected")
    }

    /// `-demoThinking` holds a question at the thinking row, with one of the design's phrases.
    @MainActor
    func testDemoThinkingShowsTheThinkingRow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-demoThinking", "YES"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        let row = app.staticTexts["thinkingRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "No thinking row")
        XCTAssertTrue(row.label.hasSuffix("…"), "Phrase was: \(row.label)")
        XCTAssertTrue(app.staticTexts["You · What about coffee?"].exists)
        // One question at a time: Send stays off while the answer is worked out.
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText("And dining?")
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        attachScreenshot(app, "ask-thinking")
    }

    /// `-demoTokenLimit` shows the limit as an ordinary Sedge turn, and "Start new session"
    /// clears the chat back to the empty screen.
    @MainActor
    func testDemoTokenLimitStartsANewSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-demoTokenLimit", "YES"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(app.staticTexts["This chat is full"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists, "The limit must not be an alert")
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertFalse(field.isEnabled, "The question box should be off at the limit")
        attachScreenshot(app, "ask-token-limit")

        // "Open previous chats" opens the panel; the backdrop closes it again.
        app.buttons["Open previous chats"].tap()
        XCTAssertTrue(app.staticTexts["Chats"].waitForExistence(timeout: 2), "The panel didn't open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Start new session"].waitForExistence(timeout: 2), "The panel didn't close")

        app.buttons["Start new session"].tap()
        XCTAssertTrue(app.staticTexts["Ask about your money"].waitForExistence(timeout: 2), "No empty screen")
        XCTAssertFalse(app.staticTexts["This chat is full"].exists)
        XCTAssertTrue(field.isEnabled)
    }

    /// A question is saved as a chat: New chat clears the screen and the Previous chats panel
    /// lists it, while New chat on an empty chat adds nothing. Opening it shows its turn under the
    /// "answers best in a new chat" banner, with no Rename under its title until New chat. A
    /// question asked there is added to it. The chat is deleted through Edit and the confirmation
    /// at the end, so Maya's file keeps no test chats.
    /// Screenshots: the toolbar, the panel, edit mode, the empty panel (when no other chats are
    /// saved) and the continued chat; for dark ones, run it after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testPreviousChatsReopenAndContinueAChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-reduceMotion", "YES"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        // A question no other test asks, so its row is easy to find among older chats.
        let question = "Previous chats test \(Int.random(in: 1000...9999))"
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText(question)
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["The assistant isn't connected yet."].waitForExistence(timeout: 5))
        attachScreenshot(app, "ask-toolbar")

        app.navigationBars.buttons["New chat"].tap()
        XCTAssertTrue(app.staticTexts["Ask about your money"].waitForExistence(timeout: 2), "New chat didn't clear")

        app.navigationBars.buttons["Previous chats"].tap()
        // Rows only: once the chat is reopened, the bar's title is a button with the same text.
        let rows = app.buttons.matching(identifier: "chatRow")
        let row = rows.matching(NSPredicate(format: "label CONTAINS %@", question)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The chat isn't in Previous chats")
        XCTAssertTrue(row.label.contains("1 question"), "Row was: \(row.label)")
        let saved = rows.count

        // The backdrop closes the panel. New chat on an empty chat leaves nothing behind.
        let backdrop = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        backdrop.tap()
        app.navigationBars.buttons["New chat"].tap()
        app.navigationBars.buttons["Previous chats"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, saved, "New chat on an empty chat saved a chat")
        row.tap()

        XCTAssertTrue(app.staticTexts["Sedge answers best in a new chat."].waitForExistence(timeout: 5), "No banner")
        XCTAssertTrue(app.staticTexts["You · \(question)"].exists)
        // The bar is named by its title.
        XCTAssertTrue(app.navigationBars[question].exists, "The title isn't the chat's")
        // That title names the chat, so tapping it must not offer Rename, which names the data.
        app.navigationBars[question].descendants(matching: .any).matching(identifier: question).firstMatch.tap()
        XCTAssertFalse(app.buttons["Rename…"].waitForExistence(timeout: 2), "A reopened chat's title offers Rename")
        field.tap()
        field.typeText("And coffee?")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["You · And coffee?"].waitForExistence(timeout: 2))
        let replies = app.staticTexts.matching(NSPredicate(format: "label == %@", "The assistant isn't connected yet."))
        XCTAssertTrue(replies.element(boundBy: 1).waitForExistence(timeout: 5), "No reply to the new question")
        attachScreenshot(app, "continued-chat")

        // The banner's New chat leaves the old chat; reopening shows both turns were saved.
        app.buttons["bannerNewChat"].tap()
        XCTAssertTrue(app.staticTexts["Ask about your money"].waitForExistence(timeout: 2))
        // A new chat is "Ask Sedge" again, and its title menu has Rename back.
        app.navigationBars["Ask Sedge"].buttons["Ask Sedge"].tap()
        XCTAssertTrue(app.buttons["Rename…"].waitForExistence(timeout: 2), "Rename didn't come back")
        app.buttons["Rename…"].tap()
        app.alerts.buttons["Cancel"].tap()
        app.navigationBars.buttons["Previous chats"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.staticTexts["You · And coffee?"].waitForExistence(timeout: 5), "The new turn wasn't saved")

        // Edit, its minus circle, Delete and the confirmation remove it from the list. It was the
        // chat on screen, so Ask starts a new one instead of saving the next question into a chat
        // that is gone.
        app.navigationBars.buttons["Previous chats"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("2 questions"), "Row was: \(row.label)")
        XCTAssertTrue(row.isSelected, "The open chat isn't marked")
        attachScreenshot(app, "chats-panel")
        app.buttons["Edit"].tap()
        app.buttons["Delete \(question)"].tap()
        attachScreenshot(app, "chats-panel-edit")
        app.buttons["Delete"].tap()
        let confirm = app.sheets.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 2), "No confirmation")
        attachScreenshot(app, "chats-delete-confirmation")
        confirm.tap()
        XCTAssertFalse(row.waitForExistence(timeout: 2), "The chat wasn't deleted")
        if rows.count == 0 {
            XCTAssertTrue(app.staticTexts["No chats yet"].exists)
            attachScreenshot(app, "chats-panel-empty")
        }
        backdrop.tap()
        XCTAssertTrue(app.staticTexts["Ask about your money"].waitForExistence(timeout: 2), "Still showing the deleted chat")
    }

    /// The empty Ask screen's example question changes every few seconds, and typing brings up
    /// the composer's underlay. Screenshots: two moments of the rotation, then typing. For dark
    /// screenshots, run it after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testAskExampleRotatesAndTypingShowsTheUnderlay() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        let example = app.buttons["exampleQuestion"]
        XCTAssertTrue(example.waitForExistence(timeout: 5))
        let first = example.label
        attachScreenshot(app, "ask-example-first")
        // Each question stays 4.3 s; allow a couple of turns so a slow simulator can't miss the swap.
        let changed = expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: example)
        wait(for: [changed], timeout: 15)
        // Let the 0.3-second crossfade finish before the screenshot.
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(app, "ask-example-second")

        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText("How much did I spend at Netflix")
        Thread.sleep(forTimeInterval: 0.5) // the underlay's spring
        attachScreenshot(app, "ask-typing")
    }

    /// No "Local analysis" line under the question box, and with the keyboard up a short drag on
    /// the chat puts it away, without the finger having to reach the keyboard.
    @MainActor
    func testAskDragOnChatDismissesTheKeyboard() throws {
        let app = XCUIApplication()
        // The sample conversation is taller than the screen, so there is something to drag.
        app.launchArguments = ["-persona", "maya", "-sampleChat", "YES"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(app.staticTexts["Food & dining"].waitForExistence(timeout: 10), "No sample chat")
        let localLine = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Local analysis'"))
        XCTAssertEqual(localLine.count, 0, "The Local analysis line is back")

        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        // A simulator that has seen a hardware keyboard keeps its keyboard just below the screen,
        // still in the element tree, so "up" means on screen, not merely present.
        let screen = app.windows.firstMatch.frame
        let keyboardUp = NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            return keyboard.exists && keyboard.frame.intersects(screen)
        }
        let shown = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: keyboardUp, object: nil)], timeout: 5)
        try XCTSkipIf(shown != .completed, "This simulator keeps its keyboard minimized; erase it to run this test")
        // From 30 % to 45 % of the screen: well above the keyboard's top edge.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        let down = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSCompoundPredicate(notPredicateWithSubpredicate: keyboardUp), object: nil)], timeout: 3)
        XCTAssertEqual(down, .completed, "The keyboard stayed up after dragging the chat")
    }

    /// A chat grown past the screen with the keyboard up: the newest reply stays above the box.
    @MainActor
    func testAskNewestTurnStaysAboveTheKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-reduceMotion", "YES"]
        app.launch()
        app.tabBars.buttons["Ask"].tap()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for i in 1...9 {
            field.typeText("Question number \(i)")
            app.buttons["Send"].tap()
            let replies = app.staticTexts.matching(identifier: "The assistant isn't connected yet.")
            wait(for: [expectation(for: NSPredicate(format: "count == \(i)"), evaluatedWith: replies)], timeout: 8)
            Thread.sleep(forTimeInterval: 0.6)
            let last = replies.element(boundBy: i - 1)
            XCTAssertLessThanOrEqual(last.frame.maxY, field.frame.minY, "reply \(i) hidden behind the box")
        }
    }

    /// With Reduce Motion on, the example question stays on the first one.
    @MainActor
    func testAskExampleStaysWithReduceMotion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-reduceMotion", "YES"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        let example = app.buttons["exampleQuestion"]
        XCTAssertTrue(example.waitForExistence(timeout: 5))
        XCTAssertEqual(example.label, "How much did I spend at Netflix this year?")
        // As long as the rotation test waits for a swap, so both watch the same window.
        Thread.sleep(forTimeInterval: 15)
        XCTAssertEqual(example.label, "How much did I spend at Netflix this year?")
    }

    /// A chat of one short line starts at the same left edge as a long one. Screenshots: the
    /// long chat, then the short one.
    @MainActor
    func testAskShortChatStartsAtTheLeft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-sampleChat", "YES", "-reduceMotion", "YES"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        let long = app.staticTexts["You · Have I been overspending on food?"]
        XCTAssertTrue(long.waitForExistence(timeout: 10), "No sample chat")
        let left = long.frame.minX
        attachScreenshot(app, "ask-long-chat")

        app.navigationBars.buttons["New chat"].tap()
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        field.typeText("hello")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["The assistant isn't connected yet."].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["You · hello"].frame.minX, left, accuracy: 1, "The short chat isn't at the left")
        attachScreenshot(app, "ask-one-question")
    }

    /// After New chat the example question is there, also with the keyboard up, and tapping it
    /// asks it. Screenshots: the empty chat, then with the keyboard up.
    @MainActor
    func testAskExampleQuestionAsksIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-sampleChat", "YES", "-reduceMotion", "YES"]
        app.launch()

        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(app.staticTexts["Food & dining"].waitForExistence(timeout: 10), "No sample chat")
        app.navigationBars.buttons["New chat"].tap()
        let example = app.buttons["exampleQuestion"]
        XCTAssertTrue(example.waitForExistence(timeout: 2), "No example after New chat")
        attachScreenshot(app, "ask-new-chat-empty")

        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        field.tap()
        Thread.sleep(forTimeInterval: 0.6) // the keyboard sliding up
        XCTAssertTrue(example.isHittable, "The example is hidden with the keyboard up")
        attachScreenshot(app, "ask-new-chat-keyboard")

        let question = example.label
        example.tap()
        XCTAssertTrue(app.staticTexts["You · \(question)"].waitForExistence(timeout: 3), "Tapping didn't ask it")
        XCTAssertTrue(app.staticTexts["The assistant isn't connected yet."].waitForExistence(timeout: 10))
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
            XCTAssertTrue(app.staticTexts["total"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["No spending yet"].exists)
            attachScreenshot(app, "\(persona) spending")

            app.buttons["cashFlow"].tap()
            let field = app.textFields["Amount"]
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

    /// Reset asks first, and both Cancel and Delete close the question. What Delete removes is
    /// checked by AskUserTests in SedgeCore.
    @MainActor
    func testResetAsksBeforeDeleting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let reset = app.buttons["Reset saved questions"]

        reset.tap()
        let question = app.alerts["Delete all saved answers?"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "Reset didn't ask first")
        XCTAssertTrue(question.staticTexts["This can't be undone."].exists)
        attachScreenshot(app, "reset-confirm")
        question.buttons["Cancel"].tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5), "Cancel didn't close the question")

        reset.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.buttons["Delete"].tap()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5), "Delete didn't close the question")
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
        // The connect screen is named for what it does, not "Transactions".
        XCTAssertTrue(app.navigationBars.staticTexts["Connect bank"].exists)
        attachScreenshot(app, "demo-bank-server-not-running")
        app.buttons["Use a sample person"].tap()
        app.buttons["Maya"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Maya"].waitForExistence(timeout: 10))
    }

    /// On Welcome, Connect bank opens the Connect bank screen, which with no Plaid server says
    /// so and leads to the sample people. Needs the Plaid server off. Ends on Maya.
    @MainActor
    func testWelcomeConnectBankOpensBankFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-emptyBank", "YES", "-firstLaunch", "YES"]
        app.launch()
        let connect = app.buttons["Connect bank"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.staticTexts["Bank server not running"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Start the Plaid server, then try again."].exists)
        XCTAssertTrue(app.navigationBars.staticTexts["Connect bank"].exists)
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
        XCTAssertTrue(app.staticTexts["total"].waitForExistence(timeout: 10))
        attachScreenshot(app, "tab-trends-spending")
        app.buttons["cashFlow"].tap()
        XCTAssertTrue(app.textFields["Amount"].waitForExistence(timeout: 10))
        attachScreenshot(app, "trends-cash-flow")

        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.buttons["Transactions"].waitForExistence(timeout: 10))
        attachScreenshot(app, "tab-accounts")

        // Each screen below opens from the Accounts list; the first nav bar button goes back to it.
        app.buttons["Transactions"].tap()
        XCTAssertTrue(app.buttons["Month"].waitForExistence(timeout: 10))
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

    /// The Cash flow card on Maya's Trends screen gives the same low point, amount and day, as
    /// the Cash flow screen it opens. The screenshots are light, or dark after
    /// `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testCashFlowCardShowsTheScreensLowPoint() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        // The toolbar link is gone; the card replaces it.
        XCTAssertTrue(app.staticTexts["total"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.buttons["Cash flow"].exists)
        let card = app.buttons["cashFlow"]
        let low = NSPredicate(format: "label CONTAINS 'Low point $'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: low, object: card)], timeout: 10), .completed)
        attachScreenshot(app, "trends-cash-flow-card")
        // E.g. "Cash flow, Low point $1,236.45 · Jul 1": the amount and the day.
        let parts = card.label.components(separatedBy: "Low point ")[1].components(separatedBy: " · ")
        XCTAssertEqual(parts.count, 2)

        card.tap()
        let lowest = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH 'Lowest projected balance' AND label CONTAINS %@ AND label CONTAINS %@", parts[0], parts[1])).firstMatch
        XCTAssertTrue(lowest.waitForExistence(timeout: 10), "Cash flow doesn't show \(parts)")
    }

    /// The Cash flow card follows the picked month. On June it has the three figures and the
    /// projected line and opens the Cash flow screen; on May (its bar tapped) it has the three
    /// figures and checking's May 30 balance, no line, and a tap opens nothing. The screenshots are
    /// light, or dark after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testCashFlowCardFollowsThePickedMonth() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let now = app.buttons["cashFlow"]
        XCTAssertTrue(now.waitForExistence(timeout: 10))
        let june = NSPredicate(format: "label BEGINSWITH 'Cash flow · June so far' AND label CONTAINS 'Money in' AND label CONTAINS 'Money out' AND label CONTAINS 'Left over' AND label CONTAINS 'Low point $'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: june, object: now)], timeout: 10), .completed, now.label)
        for _ in 0..<3 where now.frame.maxY > app.tabBars.firstMatch.frame.minY { app.swipeUp() }
        attachScreenshot(app, "cash-flow-card-june")
        now.tap()
        XCTAssertTrue(app.staticTexts["projected"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()

        for _ in 0..<3 where !app.otherElements["May"].isHittable { app.swipeDown() }
        app.otherElements["May"].tap()
        let past = app.descendants(matching: .any)["cashFlow"]
        XCTAssertTrue(past.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["cashFlow"].exists)
        XCTAssertTrue(past.label.hasPrefix("Cash flow · May 1\u{2009}–\u{2009}30,") && past.label.contains("Money in") && past.label.contains("Money out")
                      && past.label.contains("Left over") && past.label.contains("Checking · May 30, $"), past.label)
        XCTAssertFalse(past.label.contains("Low point"), past.label)
        for _ in 0..<3 where past.frame.maxY > app.tabBars.firstMatch.frame.minY { app.swipeUp() }
        attachScreenshot(app, "cash-flow-card-may")
        past.tap()
        XCTAssertFalse(app.staticTexts["projected"].waitForExistence(timeout: 2))
        XCTAssertTrue(past.exists)
    }

    /// The Cash flow screen keeps only the toolbar's info button: no shading sentence and no second
    /// "What's included" link. The bill change reads "None chosen" while off.
    @MainActor
    func testCashFlowScreenDropsExtraText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        app.buttons["cashFlow"].tap()
        XCTAssertTrue(app.staticTexts["projected"].waitForExistence(timeout: 10))
        attachScreenshot(app, "cash-flow-screen")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Shading shows'")).firstMatch.exists)
        XCTAssertTrue(app.navigationBars.buttons["What’s included"].exists)
        XCTAssertFalse(app.buttons["What’s included? →"].exists)
        // With no scenario on there is one line, so no legend.
        XCTAssertFalse(app.staticTexts["Current plan"].exists)
        let bill = app.switches["bill"]
        XCTAssertTrue(bill.waitForExistence(timeout: 5))
        XCTAssertTrue(bill.label.contains("None chosen"), bill.label)
        for _ in 0..<3 where !app.staticTexts["Preview only"].isHittable { app.swipeUp() }
        attachScreenshot(app, "cash-flow-screen-scenarios")
    }

    /// Without a bank account to project from, today's cash flow card still shows the month's figures
    /// but has no chevron and opens nothing, rather than a "No bank account" screen.
    @MainActor
    func testCashFlowCardWithoutABankAccountIsNotALink() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-noBankBalance", "YES"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let card = app.descendants(matching: .any)["cashFlow"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.hasPrefix("Cash flow · June so far") && card.label.contains("Money out"), card.label)
        XCTAssertFalse(card.label.contains("Low point"), card.label)
        XCTAssertFalse(app.buttons["cashFlow"].exists)
        card.tap()
        XCTAssertFalse(app.staticTexts["projected"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["No bank account"].exists)
    }

    /// January, Maya's first month, has no month before it in the data, so neither Trends nor the
    /// Groceries page shows a Biggest change against December, and December's bar, on the same
    /// page, can't be picked. The screenshots are light, or dark after
    /// `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testFirstDataMonthHasNoBiggestChange() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(app.staticTexts["June so far"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["biggestChange"].exists)
        app.scrollViews["months"].swipeRight()
        XCTAssertTrue(app.staticTexts["February"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["biggestChange"].exists)
        app.otherElements["January"].tap()
        XCTAssertTrue(app.staticTexts["Jan 1\u{2009}–\u{2009}30"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["biggestChange"].exists)
        attachScreenshot(app, "first-data-month")
        app.otherElements["December"].tap()
        XCTAssertFalse(app.staticTexts["Dec 1\u{2009}–\u{2009}30"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.otherElements["shownMonth"].label, "January")

        let blocks = app.buttons.matching(identifier: "categoryBlock")
        let groceries = blocks.matching(NSPredicate(format: "label BEGINSWITH 'Groceries, '")).firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()
        XCTAssertTrue(app.staticTexts["Stores"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["categoryChange"].exists)
        Thread.sleep(forTimeInterval: 0.5) // the push's slide
        attachScreenshot(app, "category-page-first-month")
    }

    /// Maya's Spending screen opens on the March to June page with June picked; one swipe right
    /// turns to November to February, her earliest, with February picked: the total, the marked
    /// bar and the mosaic's heading. Tapping January's bar picks January, and the filled dot moves
    /// left on the swipe but not on the tap. Every category over the 1st to the 30th: June $966,
    /// February $948, January $953. The screenshots are light, or dark after
    /// `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testSwipingBackShowsTheMonthsBefore() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let shown = app.otherElements["shownMonth"], dots = app.otherElements["Months"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10))
        XCTAssertEqual(shown.label, "June")
        XCTAssertEqual(app.staticTexts["total"].label, "$966")
        XCTAssertTrue(app.staticTexts["June so far"].exists)
        // Two pages, so two dots, the right one filled.
        XCTAssertEqual(dots.identifier, "filledDot1")
        XCTAssertEqual(dots.value as? String, "Mar\u{2009}–\u{2009}Jun 2026")
        attachScreenshot(app, "month-current")

        app.scrollViews["months"].swipeRight()
        XCTAssertTrue(app.staticTexts["February"].waitForExistence(timeout: 5))
        XCTAssertEqual(shown.label, "February")
        XCTAssertEqual(shown.value as? String, "$948")
        XCTAssertEqual(app.staticTexts["total"].label, "$948")
        XCTAssertEqual(dots.identifier, "filledDot0")
        XCTAssertEqual(dots.value as? String, "Nov 2025\u{2009}–\u{2009}Feb 2026")
        attachScreenshot(app, "month-earliest")

        app.otherElements["January"].tap()
        XCTAssertTrue(app.staticTexts["Jan 1\u{2009}–\u{2009}30"].waitForExistence(timeout: 5))
        XCTAssertEqual(shown.label, "January")
        XCTAssertEqual(app.staticTexts["total"].label, "$953")
        XCTAssertEqual(dots.identifier, "filledDot0")
        XCTAssertEqual(dots.value as? String, "Nov 2025\u{2009}–\u{2009}Feb 2026")
    }

    /// On Maya's Spending screen a tap picks a month and a swipe pages. From June, tapping April's
    /// bar shows April (every category over the 1st to the 30th: $975), and tapping it again keeps
    /// April instead of going back to June, on the same page. A swipe right then a swipe left come
    /// back to the last page with its newest month, June ($966), picked. Ways to save and All months
    /// are gone.
    @MainActor
    func testTappingAMonthPicksItAndSwipingPages() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let shown = app.otherElements["shownMonth"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10))
        XCTAssertEqual(shown.label, "June")
        XCTAssertFalse(app.buttons["All months & categories →"].exists)
        XCTAssertFalse(app.buttons["Ways to save →"].exists)
        XCTAssertFalse(app.staticTexts["Ways to save →"].exists)

        let april = app.otherElements["April"]
        april.tap()
        XCTAssertTrue(app.staticTexts["April"].waitForExistence(timeout: 5))
        XCTAssertEqual(shown.label, "April")
        XCTAssertEqual(shown.value as? String, "$975")
        XCTAssertEqual(app.staticTexts["total"].label, "$975")
        XCTAssertEqual(app.otherElements["Months"].value as? String, "Mar\u{2009}–\u{2009}Jun 2026")
        attachScreenshot(app, "month-tapped")

        // The picked month tapped again stays picked.
        april.tap()
        XCTAssertFalse(app.staticTexts["June so far"].waitForExistence(timeout: 2))
        XCTAssertEqual(shown.label, "April")

        app.scrollViews["months"].swipeRight()
        XCTAssertTrue(app.staticTexts["February"].waitForExistence(timeout: 5))
        app.scrollViews["months"].swipeLeft()
        XCTAssertTrue(app.staticTexts["June so far"].waitForExistence(timeout: 5))
        XCTAssertEqual(shown.label, "June")
        XCTAssertEqual(app.staticTexts["total"].label, "$966")
        XCTAssertEqual(app.otherElements["Months"].value as? String, "Mar\u{2009}–\u{2009}Jun 2026")
    }

    /// Maya's Spending screen adds up every category: June 1–30 is $966, counted by hand from her
    /// transactions, with no category chip, heading or link of the removed screens. The mosaic shows
    /// categories, the biggest change is by category (groceries fell $28.26 from May), and tapping a
    /// category's block opens that category's page. The screenshot is light, or dark after
    /// `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testAllShowsEveryCategory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(app.staticTexts["June so far"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Category"].exists, "the category chip is still there")
        for gone in ["Your patterns", "by category", "All months & categories →"] {
            XCTAssertFalse(app.staticTexts[gone].exists || app.buttons[gone].exists, gone)
        }
        XCTAssertEqual(app.staticTexts["total"].label, "$966")
        XCTAssertEqual(app.otherElements["shownMonth"].value as? String, "$966")
        let change = app.buttons["biggestChange"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        XCTAssertTrue(change.label.contains("Groceries") && change.label.contains("-$28 vs May"), change.label)
        XCTAssertTrue(app.buttons["Housing, $650"].exists)
        attachScreenshot(app, "spending-all")
        app.swipeUp()
        attachScreenshot(app, "spending-all-mosaic")

        app.buttons["Groceries, $87"].tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["categoryAmount"].label, "$87")
    }

    /// On an earlier page (November to February) with January picked, tapping the
    /// Groceries block opens Groceries' own page on January: its title, January's $83 (counted by
    /// hand over the 1st to the 30th: $19.11 + $18.87 + $20.19 + $25.01), Stores and Transactions,
    /// and no month pager. Tapping February's strip bar changes the amount, tapping a store opens
    /// its history, and going back twice finds Spending still on January. The screenshots are the page
    /// on June and on January, in light, or dark after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testAllCategoryBlockOpensTheCategoryPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let blocks = app.buttons.matching(identifier: "categoryBlock")
        let groceries = blocks.matching(NSPredicate(format: "label BEGINSWITH 'Groceries, '")).firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stores"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5) // the push's slide
        attachScreenshot(app, "category-page-june")
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(app.staticTexts["June so far"].waitForExistence(timeout: 5))
        app.scrollViews["months"].swipeRight()
        XCTAssertTrue(app.staticTexts["February"].waitForExistence(timeout: 5))
        app.otherElements["January"].tap()
        XCTAssertTrue(app.staticTexts["Jan 1\u{2009}–\u{2009}30"].waitForExistence(timeout: 5))
        let earlier = "Nov 2025\u{2009}–\u{2009}Feb 2026"
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()

        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        let amount = app.staticTexts["categoryAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertEqual(amount.label, "$83")
        XCTAssertTrue(app.staticTexts["Stores"].exists)
        XCTAssertFalse(app.scrollViews["months"].exists, "the category page has a month pager")
        XCTAssertFalse(app.buttons["Category"].exists)
        let bars = app.buttons.matching(identifier: "stripBar")
        XCTAssertEqual(bars.count, 6)
        XCTAssertTrue(bars.element(boundBy: 0).isSelected, "January isn't the picked bar")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["4 transactions"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        app.swipeDown()
        attachScreenshot(app, "category-page-january")

        bars.element(boundBy: 1).tap()
        XCTAssertTrue(bars.element(boundBy: 1).isSelected, "February isn't the picked bar")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != '$83'"), object: amount)],
                                      timeout: 5), .completed, "the amount didn't change")

        let store = app.buttons.matching(identifier: "categoryStore").firstMatch
        XCTAssertTrue(store.waitForExistence(timeout: 5))
        store.tap()
        XCTAssertTrue(app.otherElements["storeChart"].waitForExistence(timeout: 5), "no store history")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.otherElements["shownMonth"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.otherElements["shownMonth"].label, "January")
        XCTAssertEqual(app.otherElements["Months"].value as? String, earlier)
        XCTAssertTrue(app.staticTexts["Jan 1\u{2009}–\u{2009}30"].exists)
    }

    /// The question chip at the bottom of Maya's June Groceries page (down from May) opens Ask on
    /// a new chat, the sample chat set aside, with the question typed in the box and not sent.
    @MainActor
    func testCategoryQuestionOpensAskWithItTyped() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-sampleChat", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Food & dining"].waitForExistence(timeout: 10), "No sample chat")
        app.tabBars.buttons["Trends"].tap()
        let groceries = app.buttons.matching(NSPredicate(format: "identifier == 'categoryBlock' AND label BEGINSWITH 'Groceries, '")).firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()
        let chip = app.buttons["categoryQuestion"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        let question = "Why was groceries lower in June than May?"
        XCTAssertEqual(chip.label, question)
        for _ in 0..<5 where !chip.isHittable { app.swipeUp() }
        chip.tap()

        XCTAssertTrue(app.tabBars.buttons["Ask"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Ask"].isSelected)
        let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, question)
        XCTAssertFalse(app.staticTexts["Food & dining"].exists, "the sample chat is still on screen")
        XCTAssertFalse(app.staticTexts["You · \(question)"].exists, "the question was sent")
    }

    /// The Biggest change row (Groceries on Maya's June) opens Groceries' own page, and going back
    /// finds Spending again.
    @MainActor
    func testAllBiggestChangeOpensItsCategoryPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let change = app.buttons["biggestChange"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        XCTAssertTrue(change.label.contains("Groceries"), change.label)
        change.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["categoryAmount"].label, "$87")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["June so far"].waitForExistence(timeout: 5))
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
        app.buttons["cashFlow"].tap()
        let projected = app.staticTexts["projected"]
        XCTAssertTrue(projected.waitForExistence(timeout: 10))
        attachScreenshot(app, "cash-flow")
        let plan = try dollars(projected.label)

        // A $400 purchase starts switched on.
        let field = app.textFields["Amount"]
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

    /// A finger held and slid along Maya's Cash flow chart shows the day under it and that day's
    /// balance where the lowest point was, for 30, 60 and 90 days and with a purchase on; lifting
    /// it brings the lowest point back. The mid-slide screenshots are light, or dark after
    /// `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testSlidingAlongTheCashFlowChartShowsTheDaysBalance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Trends"].tap()
        app.buttons["cashFlow"].tap()
        let chart = app.descendants(matching: .any)["cashFlowChart"]
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        let readout = app.descendants(matching: .any)["readout"]
        let lowest = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Lowest projected balance'")).firstMatch

        func slide(_ name: String, expectsPlan: Bool) throws {
            XCTAssertTrue(lowest.waitForExistence(timeout: 5), name)
            XCTAssertFalse(readout.exists, name)
            let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            // A gesture call returns only after the finger lifts, but it runs the main queue while
            // it waits, so this block reads the screen during the hold, with the finger still down.
            var label: String?
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                label = readout.exists ? readout.label : nil
                self.attachScreenshot(app, "cash-flow-sliding-\(name)")
            }
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 4)
            // E.g. "Jul 21, $1,846.12" or, with a purchase on, "Jul 21, $1,446.12, Current plan, $1,846.12".
            let shown = try XCTUnwrap(label, "No readout while sliding, \(name)")
            XCTAssertNotNil(shown.range(of: #"^[A-Z][a-z]{2} \d{1,2}, -?\$[\d,]+\.\d\d"#, options: .regularExpression), "\(name): \(shown)")
            XCTAssertEqual(shown.contains("Current plan, $"), expectsPlan, "\(name): \(shown)")
            XCTAssertTrue(lowest.waitForExistence(timeout: 5), "Lowest point didn't come back, \(name)")
            XCTAssertFalse(readout.exists, "Readout stayed after lifting, \(name)")
        }

        for days in [30, 60, 90] {
            app.buttons["\(days) days"].tap()
            try slide("\(days)-days", expectsPlan: false)
        }
        let field = app.textFields["Amount"]
        field.tap()
        field.typeText("400")
        app.buttons["Add purchase"].tap()
        XCTAssertTrue(app.switches["purchase"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeDown()
        try slide("with-changes", expectsPlan: true)
    }

    /// The purchase entry and the bill amount are laid out by hand (no Form rows), so each
    /// needs its own 44 pt tall target.
    @MainActor
    func testCashFlowEntryTargetsAreAtLeast44Points() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Trends"].tap()
        app.buttons["cashFlow"].tap()
        XCTAssertTrue(app.staticTexts["projected"].waitForExistence(timeout: 10))

        // Switch "Change a bill" on to show its amount field.
        flip(app.switches["bill"], in: app)
        let billAmount = app.textFields["Change per charge"]
        XCTAssertTrue(billAmount.waitForExistence(timeout: 5))

        for (name, element) in [("Add purchase", app.buttons["Add purchase"]),
                                ("Extra purchase field", app.textFields["Amount"]),
                                ("Bill amount field", billAmount)] {
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) is \(element.frame.height) pt tall")
        }
    }

    /// A tap anywhere in the 44 pt purchase and bill fields focuses them, not only in the middle.
    @MainActor
    func testCashFlowFieldsFocusFromTheirWholeHeight() throws {
        for name in ["Amount", "Change per charge"] {
            let app = XCUIApplication()
            app.launchArguments = ["-persona", "maya"]
            app.launch()
            app.tabBars.buttons["Trends"].tap()
            app.buttons["cashFlow"].tap()
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
    /// between those categories' June amounts on their pages, and moving it back restores
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
        let row = app.buttons["Corner Cafe, $10.40"]
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["Higher than your last three visits."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Those were $8.81–$9.29."].exists)
        XCTAssertTrue(app.staticTexts["This is a spending observation, not a fraud determination."].exists)
        attachScreenshot(app, "transaction-detail")

        try pickCategory(app, "Groceries")
        attachScreenshot(app, "transaction-detail-groceries")
        let moved = (dining: try spent(app, "Dining"), groceries: try spent(app, "Groceries"))
        // The pages show whole dollars, so $10.40 moves by 10 or 11 after rounding.
        XCTAssertTrue((10...11).contains(before.dining - moved.dining), "Dining went from \(before.dining) to \(moved.dining)")
        XCTAssertTrue((10...11).contains(moved.groceries - before.groceries), "Groceries went from \(before.groceries) to \(moved.groceries)")

        // Back to the store's own category, which clears the answer.
        app.tabBars.buttons["Accounts"].tap()
        try pickCategory(app, "Dining")
        XCTAssertEqual(try spent(app, "Dining"), before.dining)
        XCTAssertEqual(try spent(app, "Groceries"), before.groceries)
    }

    /// Maya's Jun 30 Bean Street Coffee charge opens the store's Merchant history: June's $12.71
    /// total, the six-month chart ending at June, and June's first week. The screenshot is the
    /// screen in light, or dark after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testMerchantHistoryShowsTotalChartAndWeeks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Transactions"].tap()
        let row = app.buttons["Bean Street Coffee, $2.68"]
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merchant history'")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        for _ in 0..<5 where !history.isHittable { app.swipeUp() }
        history.tap()

        let any = app.descendants(matching: .any)
        XCTAssertTrue(any.matching(NSPredicate(format: "label BEGINSWITH '$12.71'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(any["storeChart"].exists)
        XCTAssertTrue(any.matching(NSPredicate(format: "label == 'January, $10.25'")).firstMatch.exists)
        XCTAssertTrue(any.matching(NSPredicate(format: "label == 'June, $12.71'")).firstMatch.exists)
        XCTAssertTrue(any.matching(NSPredicate(format: "label BEGINSWITH 'Jun 29 – Jul 5'")).firstMatch.exists)
        // The bars grow in about half a second; the screenshot waits for them.
        sleep(1)
        attachScreenshot(app, "merchant-history")
    }

    /// The Transaction screen's "Merchant history" subtitle counts the rows the history lists:
    /// Maya's Bean Street history lists 26 visits, so the subtitle says 26, not every row there (41).
    @MainActor
    func testMerchantHistorySubtitleMatchesHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Transactions"].tap()
        let row = app.buttons["Bean Street Coffee, $2.68"]
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merchant history'")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        let subtitle = history.label
        for _ in 0..<5 where !history.isHittable { app.swipeUp() }
        history.tap()

        let card = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '26 visits since'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(subtitle.contains("26 visits"), "subtitle was '\(subtitle)', history shows '\(card.label)'")
    }

    /// Maya's transactions open on June: the in/out card (In +$1,040.00, Out $966.00) and one
    /// run of week headers, the payroll week carrying both its in and out. The month menu moves
    /// to May, and back in June a row opens the Transaction screen. The screenshot is the screen
    /// in light, or dark after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testTransactionsWeekListAndMonthMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Transactions"].tap()
        let any = app.descendants(matching: .any)
        let label = { (start: String) in any.matching(NSPredicate(format: "label BEGINSWITH %@", start)).firstMatch }
        XCTAssertTrue(label("In, +$1,040.00").waitForExistence(timeout: 10))
        XCTAssertTrue(label("Out, $966.00").exists)
        XCTAssertTrue(app.staticTexts["$74.00 left over"].exists)
        XCTAssertTrue(label("Jun 29 – Jul 5, $28.19").exists)
        XCTAssertTrue(label("Jun 15 – 21, +$520.00, $118.21").exists)
        XCTAssertFalse(app.staticTexts["Income"].exists)
        attachScreenshot(app, "transactions-weeks")

        let menu = app.buttons["Month"]
        XCTAssertEqual(menu.value as? String, "June 2026")
        menu.tap()
        app.buttons["May 2026"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Month' AND value == 'May 2026'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(label("May 25 – 31").waitForExistence(timeout: 5))
        XCTAssertFalse(label("Jun 15 – 21").exists)

        menu.tap()
        app.buttons["June 2026"].tap()
        let row = app.buttons["Bean Street Coffee, $2.68"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merchant history'")).firstMatch.waitForExistence(timeout: 10))
    }

    /// Sideways swipes on Transactions, slow or fast, change the month and stay on the screen. A
    /// row's screen still goes back with a swipe across it, and the swipe from the screen's left
    /// edge still leaves Transactions.
    @MainActor
    func testTransactionsSwipeChangesMonthAndStays() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Transactions"].tap()
        let menu = app.buttons["Month"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertEqual(menu.value as? String, "June 2026")
        let month = { (name: String) in app.buttons.matching(NSPredicate(format: "label == 'Month' AND value == %@", name)).firstMatch }
        // A drag across the list between two fractions of the screen's width.
        let swipe = { (from: CGFloat, to: CGFloat, velocity: XCUIGestureVelocity) in
            app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.55))
                .press(forDuration: 0, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.56)), withVelocity: velocity, thenHoldForDuration: 0)
        }
        // "About you" is a row on the Accounts list, so seeing it means the screen went back.
        let accounts = app.buttons["About you"]
        let stillHere = {
            XCTAssertTrue(menu.exists, "Transactions is no longer showing")
            XCTAssertFalse(accounts.exists, "The swipe went back to Accounts")
        }

        // A finger often rests a moment before it moves. Without the fix, this drag went back to Accounts.
        let restThenSwipe = { (from: CGFloat, to: CGFloat) in
            app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.55))
                .press(forDuration: 0.4, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.55)), withVelocity: 1500, thenHoldForDuration: 0)
        }
        restThenSwipe(0.3, 0.6)
        sleep(1)
        XCTAssertFalse(accounts.exists, "A resting swipe went back to Accounts")
        XCTAssertTrue(month("May 2026").waitForExistence(timeout: 5), "A resting swipe right didn't show May")
        restThenSwipe(0.7, 0.4)
        XCTAssertTrue(month("June 2026").waitForExistence(timeout: 5), "A resting swipe left didn't show June")
        stillHere()

        swipe(0.2, 0.85, .slow)
        XCTAssertTrue(month("May 2026").waitForExistence(timeout: 5), "A slow swipe right didn't show May")
        stillHere()
        app.swipeRight()
        XCTAssertTrue(month("April 2026").waitForExistence(timeout: 5), "A swipe right didn't show April")
        stillHere()
        swipe(0.15, 0.6, .fast)
        XCTAssertTrue(month("March 2026").waitForExistence(timeout: 5), "A fast swipe right didn't show March")
        stillHere()
        swipe(0.85, 0.2, .slow)
        XCTAssertTrue(month("April 2026").waitForExistence(timeout: 5), "A slow swipe left didn't show April")
        app.swipeLeft()
        XCTAssertTrue(month("May 2026").waitForExistence(timeout: 5), "A swipe left didn't show May")
        swipe(0.85, 0.4, .fast)
        XCTAssertTrue(month("June 2026").waitForExistence(timeout: 5), "A fast swipe left didn't show June")
        stillHere()

        // The swipe-anywhere back gesture is only off on Transactions: a row's screen keeps it.
        let row = app.buttons["Bean Street Coffee, $2.68"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merchant history'")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        swipe(0.1, 0.65, .fast)
        XCTAssertTrue(history.waitForNonExistence(timeout: 5), "A swipe on the row's screen didn't go back")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))

        // The swipe from the left edge of the screen still goes back.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55)))
        XCTAssertTrue(accounts.waitForExistence(timeout: 5), "The edge swipe didn't go back")
    }


    /// Opens the Accounts screen from the Accounts tab's row. The row and the tab share the name
    /// "Accounts", so the row is looked for in the list.
    private func openAccountsList(_ app: XCUIApplication) {
        app.tabBars.buttons["Accounts"].tap()
        app.collectionViews.buttons["Accounts"].tap()
    }

    /// Starting with both of Maya's accounts unanswered, the Accounts row says so, opens
    /// "Accounts", and asks about each account right there. Shared moves Checking into Answered;
    /// Decide later keeps Credit Card's question at the top. An answered account still opens its
    /// check to change the answer. Clears the answers at the end, so Maya's saved file ends as it was.
    @MainActor
    func testAnsweringInPlaceMovesTheAccountToAnswered() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-clearOwnerAnswers", "YES"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let row = app.collectionViews.buttons["Accounts"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(row.value as? String, "2 unanswered")
        attachScreenshot(app, "accounts-tab")
        row.tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))

        // Each question card is a group named for its account, holding the three answers.
        let checkingCard = app.otherElements["Checking"]
        let cardCard = app.otherElements["Credit Card"]
        XCTAssertTrue(checkingCard.waitForExistence(timeout: 10))
        XCTAssertTrue(cardCard.exists)
        attachScreenshot(app, "accounts-to-answer")
        checkingCard.buttons["Shared"].tap()
        let checking = app.buttons["Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        XCTAssertEqual(checking.value as? String, "Shared")
        XCTAssertTrue(checkingCard.waitForNonExistence(timeout: 5))

        cardCard.buttons["Decide later"].tap()
        XCTAssertTrue(cardCard.exists)
        XCTAssertFalse(app.buttons["Credit Card"].exists)
        attachScreenshot(app, "accounts-answered")

        // An answered account opens its check, and a new answer shows on its row.
        checking.tap()
        XCTAssertTrue(app.staticTexts["Is this account yours?"].waitForExistence(timeout: 5))
        app.buttons["Yes, mine"].tap()
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        XCTAssertEqual(checking.value as? String, "Yours")

        // Back on the tab, the row counts the one still to answer.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "1 unanswered")

        // The app has no way to take an owner answer back, so a debug launch argument clears them.
        app.terminate()
        app.launchArguments = ["-persona", "maya", "-clearOwnerAnswers", "YES"]
        app.launch()
        openAccountsList(app)
        XCTAssertTrue(checkingCard.waitForExistence(timeout: 10))
    }

    /// A name typed in the account check shows on Accounts in place of the bank's name, and
    /// clearing the field brings the bank's name back. Clears the answers at the end, so Maya's
    /// saved file ends as it was.
    @MainActor
    func testNamingAnAccountShowsTheNameOnAccounts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-clearOwnerAnswers", "YES"]
        app.launch()
        openAccountsList(app)

        // Only an answered account opens the check, so answer Checking first.
        let checkingCard = app.otherElements["Checking"]
        XCTAssertTrue(checkingCard.waitForExistence(timeout: 10))
        checkingCard.buttons["Yes, mine"].tap()
        let checking = app.buttons["Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        checking.tap()
        let field = app.textFields["Account name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Everyday")
        attachScreenshot(app, "account-check-named")
        app.buttons["Decide later"].tap()

        let named = app.buttons["Everyday"]
        XCTAssertTrue(named.waitForExistence(timeout: 5))
        XCTAssertFalse(checking.exists)
        attachScreenshot(app, "your-accounts-named")

        // Clear the name: the row goes back to the bank's name.
        named.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["Clear name"].tap()
        app.buttons["Decide later"].tap()
        XCTAssertTrue(checking.waitForExistence(timeout: 5))
        XCTAssertFalse(named.exists)

        app.terminate()
        app.launchArguments = ["-persona", "maya", "-clearOwnerAnswers", "YES"]
        app.launch()
    }

    /// After a bank connection, each unanswered account is asked about once, one after another.
    /// The launch argument stands in for a finished Plaid sync, so no quickstart server is needed.
    /// Decide later answers nothing, so Maya's saved file stays as it was.
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
            app.buttons["Decide later"].tap()
            // Wait for this sheet to go before looking for the next one.
            XCTAssertTrue(app.staticTexts[name].waitForNonExistence(timeout: 5))
            if asked.count > 2 { break }
        }
        // Maya has two accounts; one may already be answered by another test on this simulator.
        XCTAssertFalse(asked.isEmpty)
        XCTAssertEqual(asked.count, Set(asked).count, "An account was asked about twice")
        XCTAssertTrue(app.tabBars.buttons["Ask"].isHittable)
    }

    /// After connecting, each answer moves the count on ("Account 1 of 2", then "2 of 2") and saves
    /// what Accounts shows: Yes, mine as Yours, Shared as Shared, with the bank's names kept
    /// because no name was typed. Clears the answers at the end, so Maya's saved file ends as it was.
    @MainActor
    func testQuickCheckAfterConnectingCountsAndSavesEachAnswer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya", "-clearOwnerAnswers", "YES", "-checkAccountsAfterConnecting", "YES"]
        app.launch()

        // Maya's accounts come in name order: Checking, then Credit Card.
        XCTAssertTrue(app.descendants(matching: .any)["Account 1 of 2"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Checking"].exists)
        attachScreenshot(app, "account-check-1-of-2")
        app.buttons["Yes, mine"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["Account 2 of 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Credit Card"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["Account 1 of 2"].exists)
        attachScreenshot(app, "account-check-2-of-2")
        app.buttons["Shared"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Account 2 of 2"].waitForNonExistence(timeout: 5))

        openAccountsList(app)
        let checking = app.buttons["Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        XCTAssertEqual(checking.value as? String, "Yours")
        XCTAssertEqual(app.buttons["Credit Card"].value as? String, "Shared")

        app.terminate()
        app.launchArguments = ["-persona", "maya", "-clearOwnerAnswers", "YES"]
        app.launch()
        openAccountsList(app)
        // Unanswered again, so Checking is back as a question at the top.
        XCTAssertTrue(app.otherElements["Checking"].waitForExistence(timeout: 10))
    }

    /// "Don’t show this again" in the spending note's row hides it on every transaction, not just
    /// the one it was tapped on: the row counts down like the familiar prompt, then leaves the list.
    /// The Accounts tab's "Show the spending note again" row brings it back. The note ends shown,
    /// as it started. For dark screenshots, run it after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testSpendingNoteHidesEverywhereAndComesBack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let showAgain = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show the spending note again'")).firstMatch
        // A run stopped halfway may have left the note hidden; start with it shown.
        if showAgain.waitForExistence(timeout: 3) { showAgain.tap() }

        let corner = "Corner Cafe, $10.40"
        let note = app.staticTexts["This is a spending observation, not a fraud determination."]
        let hiddenLine = app.staticTexts["Spending note hidden on every transaction"]
        let closing = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Closing in '")).firstMatch
        openTransaction(app, corner)
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        attachScreenshot(app, "note-row")
        app.buttons["Don’t show this again"].tap()
        XCTAssertTrue(hiddenLine.waitForExistence(timeout: 2))
        XCTAssertTrue(closing.exists)
        XCTAssertTrue(app.buttons["Undo"].exists)
        XCTAssertFalse(note.exists)
        attachScreenshot(app, "note-row-hidden-undo")
        // The row counts down 4 s, then leaves the list.
        XCTAssertTrue(hiddenLine.waitForNonExistence(timeout: 7))
        XCTAssertFalse(closing.exists)
        XCTAssertFalse(note.exists)
        attachScreenshot(app, "note-row-gone")

        // Another purchase at the same store has Sedge's context too, and no note either.
        app.navigationBars.buttons.firstMatch.tap()
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Corner Cafe, ' AND label != %@", corner)).firstMatch
        for _ in 0..<10 where !(other.exists && other.isHittable) { app.swipeUp() }
        other.tap()
        XCTAssertTrue(app.staticTexts["Sedge’s context"].waitForExistence(timeout: 10))
        XCTAssertFalse(note.exists)
        XCTAssertFalse(app.buttons["Don’t show this again"].exists)

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

    /// Undo in the spending note's row keeps the note: it is back in the row at once, stays after
    /// the countdown would have ended, shows on another transaction, and the Accounts tab offers
    /// nothing to bring back. Also checks the Category row has no subtext under it: it is shorter
    /// than the Merchant history row, which keeps its "N transactions" line.
    @MainActor
    func testSpendingNoteUndoKeepsItShownEverywhere() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let showAgain = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show the spending note again'")).firstMatch
        // A run stopped halfway may have left the note hidden; start with it shown.
        if showAgain.waitForExistence(timeout: 3) { showAgain.tap() }

        let corner = "Corner Cafe, $10.40"
        let note = app.staticTexts["This is a spending observation, not a fraud determination."]
        let hiddenLine = app.staticTexts["Spending note hidden on every transaction"]
        openTransaction(app, corner)
        XCTAssertTrue(note.waitForExistence(timeout: 10))

        // The Category row is one line tall; Merchant history keeps its count under the title.
        let category = app.buttons["Category"]
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merchant history'")).firstMatch
        XCTAssertTrue(category.exists && history.exists)
        XCTAssertLessThan(category.frame.height, history.frame.height, "The Category row still has a line under its title")

        app.buttons["Don’t show this again"].tap()
        XCTAssertTrue(hiddenLine.waitForExistence(timeout: 2))
        app.buttons["Undo"].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 2))
        XCTAssertFalse(hiddenLine.exists)
        // Past the 4 s the countdown would have run, the note is still there.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(note.exists)
        XCTAssertTrue(app.buttons["Don’t show this again"].exists)

        // Another purchase at the same store shows it too.
        app.navigationBars.buttons.firstMatch.tap()
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Corner Cafe, ' AND label != %@", corner)).firstMatch
        for _ in 0..<10 where !(other.exists && other.isHittable) { app.swipeUp() }
        other.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 10))

        // Nothing to bring back on the Accounts tab.
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Saved answers"].waitForExistence(timeout: 5))
        XCTAssertFalse(showAgain.exists)
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
        let corner = "Corner Cafe, $10.40"
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

        // The countdown line under the buttons, "Saved. Closing in 4" down to 0.
        let countdown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved. Closing in '")).firstMatch

        // Undo before 0: the answer is cleared and nothing is saved.
        yes.tap()
        XCTAssertTrue(countdown.waitForExistence(timeout: 2))
        // Both buttons stay while it counts, the chosen one selected.
        XCTAssertTrue(yes.isSelected)
        XCTAssertTrue(notSure.exists)
        attachScreenshot(app, "familiar-countdown")
        app.buttons["Undo"].tap()
        XCTAssertTrue(countdown.waitForNonExistence(timeout: 2))
        XCTAssertFalse(yes.isSelected)
        XCTAssertFalse(notSure.isSelected)
        reopen()
        XCTAssertFalse(yes.isSelected)
        XCTAssertFalse(notSure.isSelected)

        // Waiting past 0: the whole prompt folds away and the answer stays.
        notSure.tap()
        XCTAssertTrue(countdown.waitForExistence(timeout: 2))
        XCTAssertTrue(notSure.isSelected)
        XCTAssertFalse(yes.isSelected)
        // The countdown reaches 0 before the prompt folds away. 0 shows for well under a second and
        // waitForExistence checks only about once a second, so this reads the line's label in a
        // tight loop until it's gone. One snapshot per read, so a fold mid-read can't fail.
        var seen: Set<String> = []
        let end = Date().addingTimeInterval(7)
        while Date() < end, let label = try? countdown.snapshot().label { seen.insert(label) }
        XCTAssertTrue(seen.contains("Saved. Closing in 1"), "The countdown was never seen at 1; saw \(seen.sorted())")
        XCTAssertTrue(seen.contains("Saved. Closing in 0"), "The countdown never showed 0; saw \(seen.sorted())")
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

    /// The countdown pauses while Merchant history is open. Coming back, the track must still match
    /// the number: at "Closing in 2" or more it's at least a quarter full, so its leading edge is
    /// the accent color, not the empty track's color. At 1 an empty track is right, so a trip that
    /// comes back that late (a busy machine) can't tell and is tried again. The answer is undone at the end.
    @MainActor
    func testFamiliarTrackKeepsStepAfterMerchantHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let corner = "Corner Cafe, $10.40"
        openTransaction(app, corner)
        let yes = app.buttons["Yes"], notSure = app.buttons["Not sure"]
        let countdown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved. Closing in '")).firstMatch
        let history = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merchant history'")).firstMatch
        for _ in 0..<3 {
            XCTAssertTrue(yes.waitForExistence(timeout: 10))
            XCTAssertTrue(history.exists)
            // Leaves right after answering, so the count is still high when it comes back.
            yes.tap()
            history.tap()
            // Stay away longer than the whole 4 s countdown.
            Thread.sleep(forTimeInterval: 5)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(countdown.waitForExistence(timeout: 2))
            // The screenshot comes first, so the number read after it is never higher than the one it shows.
            let shot = app.screenshot()
            let label = countdown.label
            guard label.hasSuffix(" 2") || label.hasSuffix(" 3") || label.hasSuffix(" 4") else {
                // Too late to tell: let it fold, then open the transaction again and retry.
                XCTAssertTrue(app.staticTexts["Does this look familiar?"].waitForNonExistence(timeout: 3))
                app.navigationBars.buttons.firstMatch.tap()
                app.buttons[corner].tap()
                continue
            }
            // The track sits 4 pt tall just above the 44 pt line that holds the countdown text.
            let left = yes.frame.minX, right = notSure.frame.maxX, y = countdown.frame.midY - 22 - 2
            let near = pixel(shot.image, x: left + (right - left) * 0.05, y: y)
            let far = pixel(shot.image, x: left + (right - left) * 0.98, y: y)
            app.buttons["Undo"].tap()
            XCTAssertNotEqual(near, far, "At '\(label)' the track's leading edge has the same color as its empty end")
            return
        }
        // Clean up the saved answer before failing.
        yes.tap()
        app.buttons["Undo"].tap()
        XCTFail("Never came back from Merchant history at 'Closing in 2' or more")
    }

    /// The RGBA bytes of one point of a screenshot, `x` and `y` in points.
    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) -> [UInt8] {
        let cg = image.cgImage!
        let px = Int(x * image.scale), py = Int(y * image.scale)
        var out = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draws the image shifted so the wanted pixel lands on the 1 x 1 canvas (Core Graphics counts y from the bottom).
        ctx.draw(cg, in: CGRect(x: -px, y: py - cg.height + 1, width: cg.width, height: cg.height))
        return out
    }

    /// From the Accounts tab, opens the transaction whose row reads `label`. The list shows one
    /// month at a time and opens on the data's latest month, so this swipes back a month at a time
    /// until the row turns up or the month menu shows no earlier month.
    @MainActor
    private func openTransaction(_ app: XCUIApplication, _ label: String) {
        app.buttons["Transactions"].tap()
        let row = app.buttons[label], menu = app.buttons["Month"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        while true {
            for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
            let shown = menu.value as? String
            if row.exists && row.isHittable { break }
            app.swipeRight()
            if menu.value as? String == shown { break }
        }
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

    /// One category's June amount, in whole dollars (Maya's today is Jun 30), read from its own page:
    /// Trends' Other categories block opens June's categories, whose row opens the page.
    @MainActor
    private func spent(_ app: XCUIApplication, _ category: String) throws -> Int {
        app.tabBars.buttons["Trends"].tap()
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Other categories, '")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'monthCategory' AND label == %@", category)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let amount = app.staticTexts["categoryAmount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        let value = amount.label.filter(\.isNumber)
        app.navigationBars.buttons.firstMatch.tap()
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

    /// The Trends tab's screen is titled "Trends". Maya's June "Other categories" block opens the
    /// month's categories sheet, with "June so far" as its inline nav bar title and Done in that bar,
    /// every category of June, biggest first, and tapping Transport opens Transport's page. On
    /// May, cut short at the 30th, the sheet's title names its days. The screenshot is the sheet in
    /// light, or dark after `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testSpendingAllOtherCategoriesOpensTheMonthsCategories() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()
        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(app.navigationBars["Trends"].waitForExistence(timeout: 10), "the Trends tab isn't titled Trends")
        XCTAssertFalse(app.navigationBars["Spending"].exists)
        let block = app.buttons["Other categories, $169"]
        XCTAssertTrue(block.waitForExistence(timeout: 10), "no Other categories block")
        block.tap()
        let rows = app.buttons.matching(identifier: "monthCategory")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "tapping Other categories opened nothing")
        let sheetBar = app.navigationBars["June so far"]
        XCTAssertTrue(sheetBar.exists, "the sheet has no nav bar title")
        XCTAssertTrue(sheetBar.buttons["Done"].exists, "Done isn't in the sheet's nav bar")
        XCTAssertEqual(rows.allElementsBoundByIndex.map(\.label),
                       ["Housing", "Groceries", "Phone internet", "Utilities", "Transport", "Dining", "Education", "Subscriptions", "Coffee"])
        Thread.sleep(forTimeInterval: 0.5) // the sheet's slide
        attachScreenshot(app, "month-categories-sheet")

        rows.matching(NSPredicate(format: "label == 'Transport'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Transport"].waitForExistence(timeout: 5))
        XCTAssertFalse(rows.firstMatch.exists, "the sheet stayed open")
        XCTAssertTrue(app.staticTexts["categoryAmount"].exists)

        app.navigationBars.buttons.firstMatch.tap()
        app.otherElements["May"].tap()
        let may = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Other categories, '")).firstMatch
        XCTAssertTrue(may.waitForExistence(timeout: 5))
        may.tap()
        XCTAssertTrue(app.navigationBars["May 1\u{2009}–\u{2009}30"].waitForExistence(timeout: 5), "no day range on May's sheet")
        attachScreenshot(app, "month-categories-sheet-may")
    }

    /// Maya's May, cut short at the 30th, is headed "May 1 – 30" on Trends. June's Groceries has one
    /// store (Value Mart), so its page has no Biggest change row and its transactions heading is only
    /// the count; Phone internet's page lists its two stores. Moving the Jun 18 Corner Cafe
    /// charge to Other gives June an Other page whose question reads "other things"; moving it back
    /// leaves Maya's saved file as it was. The screenshots are light, or dark after
    /// `xcrun simctl ui <device> appearance dark`.
    @MainActor
    func testCategoryPagesForOneStoreManyStoresAndOther() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(app.staticTexts["June so far"].waitForExistence(timeout: 10))
        app.otherElements["May"].tap()
        XCTAssertTrue(app.staticTexts["May 1\u{2009}–\u{2009}30"].waitForExistence(timeout: 5), "May isn't named by its days")
        attachScreenshot(app, "trends-may-cut-short")
        app.otherElements["June"].tap()
        XCTAssertTrue(app.staticTexts["June so far"].waitForExistence(timeout: 5))

        let groceries = app.buttons.matching(NSPredicate(format: "identifier == 'categoryBlock' AND label BEGINSWITH 'Groceries, '")).firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()
        XCTAssertTrue(app.staticTexts["Stores"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "categoryStore").count, 1)
        XCTAssertFalse(app.buttons["categoryChange"].exists, "one store still has a Biggest change row")
        XCTAssertFalse(app.staticTexts["Transactions"].exists)
        Thread.sleep(forTimeInterval: 0.5) // the push's slide
        attachScreenshot(app, "category-page-one-store")
        app.navigationBars.buttons.firstMatch.tap()

        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Other categories, '")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier == 'monthCategory' AND label == 'Phone internet'")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        phone.tap()
        XCTAssertTrue(app.navigationBars["Phone internet"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "categoryStore").count, 2)
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(app, "category-page-many-stores")
        app.navigationBars.buttons.firstMatch.tap()

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Transactions"].tap()
        let row = app.buttons["Corner Cafe, $10.40"]
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        try pickCategory(app, "Other")

        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        let otherRow = app.buttons.matching(NSPredicate(format: "identifier == 'monthCategory' AND label == 'Other'")).firstMatch
        XCTAssertTrue(otherRow.waitForExistence(timeout: 5))
        otherRow.tap()
        XCTAssertTrue(app.navigationBars["Other"].waitForExistence(timeout: 5))
        let chip = app.buttons["categoryQuestion"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertEqual(chip.label, "Why was spending on other things higher in June than May?")
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(app, "category-page-other")
        app.navigationBars.buttons.firstMatch.tap()

        // Back to the store's own category, which clears the answer.
        app.tabBars.buttons["Accounts"].tap()
        try pickCategory(app, "Dining")
    }

    /// Spending reads the data again each time it shows: moving Maya's Jun 18 Corner Cafe charge
    /// ($10.40) out of Dining into Groceries, with the app open, raises June's Groceries block.
    /// Moving it back restores it, so Maya's saved file ends as it was.
    @MainActor
    func testTrendsScreensReloadWhenShown() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-persona", "maya"]
        app.launch()

        app.tabBars.buttons["Trends"].tap()
        let groceries = app.buttons.matching(NSPredicate(format: "identifier == 'categoryBlock' AND label BEGINSWITH 'Groceries, '")).firstMatch
        let before = try blockDollars(groceries)

        app.tabBars.buttons["Accounts"].tap()
        app.buttons["Transactions"].tap()
        let row = app.buttons["Corner Cafe, $10.40"]
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        try pickCategory(app, "Groceries")

        app.tabBars.buttons["Trends"].tap()
        let raised = NSPredicate(format: "label != %@", "Groceries, $\(before)")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: raised, object: groceries)], timeout: 5), .completed)
        let after = try blockDollars(groceries)
        XCTAssertTrue((10...11).contains(after - before), "June Groceries went from \(before) to \(after)")

        // Back to the store's own category, which clears the answer.
        app.tabBars.buttons["Accounts"].tap()
        try pickCategory(app, "Dining")
        app.tabBars.buttons["Trends"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Groceries, $\(before)"),
                                                                     object: groceries)], timeout: 5), .completed)
    }

    /// A mosaic block's amount, from a label such as "Groceries, $87", in whole dollars.
    @MainActor
    private func blockDollars(_ block: XCUIElement) throws -> Int {
        XCTAssertTrue(block.waitForExistence(timeout: 10))
        let value = block.label.filter(\.isNumber)
        return try XCTUnwrap(Int(value), "Not a number: \(value)")
    }
}
