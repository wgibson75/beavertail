//
//  FilteringUITests.swift
//  BeaverTailUITests
//
//  Tier 5: the bottom-pane regex Filter. Uses the pane's state messages as robust
//  observables (the top pane always shows every line, so content alone is
//  ambiguous):
//    • no filter       → "Enter a regex pattern above to filter log lines"
//    • filter, matches → neither message (the results table is shown)
//    • filter, no match→ "No lines matched"
//

import XCTest

final class FilteringUITests: BeaverTailUITestCase {

    private let emptyPrompt = "Enter a regex pattern above to filter log lines"
    private let noMatches = "No lines matched"

    // MARK: - T5.1 A matching filter shows results (both messages gone).

    func testMatchingFilterShowsResults() {
        let log = makeTempLog("apple pie\nbanana split\napple tart\ncherry")
        let app = launchApp(openingFiles: [log])
        XCTAssertTrue(app.staticTexts[emptyPrompt].waitForExistence(timeout: 20),
                      "The empty-filter prompt should show before filtering.")

        applyFilter("apple", in: app)

        XCTAssertTrue(app.staticTexts[emptyPrompt].waitForNonExistence(timeout: 10),
                      "The empty-filter prompt should disappear once a filter is applied.")
        XCTAssertFalse(app.staticTexts[noMatches].exists,
                       "A filter that matches lines must not show the no-matches message.")
    }

    // MARK: - T5.2 A non-matching filter shows the no-matches message.

    func testNonMatchingFilterShowsNoMatches() {
        let log = makeTempLog("apple\nbanana\ncherry")
        let app = launchApp(openingFiles: [log])
        XCTAssertTrue(app.staticTexts[emptyPrompt].waitForExistence(timeout: 20))

        applyFilter("zzznomatch", in: app)

        XCTAssertTrue(app.staticTexts[noMatches].waitForExistence(timeout: 10),
                      "A filter matching nothing should show the no-matches message.")
    }

    // MARK: - T5.3 An invalid regex is handled gracefully (no crash/hang).

    func testInvalidRegexIsHandledGracefully() {
        let log = makeTempLog("apple\nbanana\ncherry")
        let app = launchApp(openingFiles: [log])
        XCTAssertTrue(app.staticTexts[emptyPrompt].waitForExistence(timeout: 20))

        applyFilter("[unclosed", in: app)

        // The app must stay responsive: the Filter field is still present and the
        // window is still there (an invalid regex reports a message rather than
        // matching, so the plain no-matches state is not shown).
        XCTAssertTrue(app.textFields["filterField"].waitForExistence(timeout: 10),
                      "The Filter field should remain available after an invalid regex.")
        XCTAssertTrue(app.windows.firstMatch.exists, "The main window should remain open.")
    }

    // MARK: - T5.4 Clearing the filter restores the empty-filter prompt.

    func testClearingFilterRestoresPrompt() {
        let log = makeTempLog("apple\nbanana\napricot")
        let app = launchApp(openingFiles: [log])
        XCTAssertTrue(app.staticTexts[emptyPrompt].waitForExistence(timeout: 20))

        applyFilter("ap", in: app)
        XCTAssertTrue(app.staticTexts[emptyPrompt].waitForNonExistence(timeout: 10))

        // Clear the field back to empty and submit.
        let field = app.textFields["filterField"]
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText("\r")

        XCTAssertTrue(app.staticTexts[emptyPrompt].waitForExistence(timeout: 10),
                      "Clearing the filter should restore the empty-filter prompt.")
    }
}
