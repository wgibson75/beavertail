//
//  LineHidingUITests.swift
//  BeaverTailUITests
//
//  Tier 6: hiding lines from the top-pane context menu surfaces the Reset
//  affordance and updates the line-count summary; clicking Reset restores the
//  full view. Regression guard for the Reset-button work.
//

import XCTest

final class LineHidingUITests: BeaverTailUITestCase {

    func testHideLinesShowsResetThenRestoresFullView() {
        let text = (0..<20).map { "line \($0)" }.joined(separator: "\n")
        let log = makeTempLog(text)
        let app = launchApp(openingFiles: [log])
        XCTAssertTrue(app.staticTexts[log.lastPathComponent].waitForExistence(timeout: 20))

        // The summary starts as "20 lines".
        XCTAssertTrue(app.staticTexts["20 lines"].waitForExistence(timeout: 10),
                      "The top-pane summary should report the full line count.")

        // Right-click a middle row in the top-pane table and hide the lines above it.
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10), "The top-pane table should exist.")
        table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()

        let hideAbove = app.menuItems["Hide Lines Above"]
        XCTAssertTrue(hideAbove.waitForExistence(timeout: 5), "Hide Lines Above should be offered.")
        hideAbove.click()

        // The Reset affordance appears and the full-count summary is replaced.
        XCTAssertTrue(element("resetHiddenLinesButton", in: app).waitForExistence(timeout: 10),
                      "The Reset button should appear once lines are hidden.")
        XCTAssertTrue(app.staticTexts["20 lines"].waitForNonExistence(timeout: 10),
                      "The full-count summary should change once lines are hidden.")

        // Click Reset → full view restored, affordance gone.
        element("resetHiddenLinesButton", in: app).click()
        XCTAssertTrue(app.staticTexts["20 lines"].waitForExistence(timeout: 10),
                      "Reset should restore the full line count.")
        XCTAssertTrue(element("resetHiddenLinesButton", in: app).waitForNonExistence(timeout: 10),
                      "The Reset button should disappear once all lines are shown again.")
    }
}
