//
//  HighlightFiltersWindowUITests.swift
//  BeaverTailUITests
//
//  Tier 3: the Highlight Filters toolbar toggle opens and closes its standalone
//  window.
//

import XCTest

final class HighlightFiltersWindowUITests: BeaverTailUITestCase {

    func testToggleOpensAndClosesHighlightFiltersWindow() {
        // Launch with a file so the full toolbar (including the highlight toggle) is
        // present.
        let url = makeTempLog("line one\nline two")
        let app = launchApp(openingFiles: [url])
        XCTAssertTrue(app.staticTexts[url.lastPathComponent].waitForExistence(timeout: 20))

        let toggle = highlightFiltersToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "The Highlight Filters toolbar toggle should be present.")

        toggle.click()
        let window = app.windows["Highlight Filters"]
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "Clicking the toggle should open the Highlight Filters window.")

        toggle.click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 10),
                      "Clicking the toggle again should close the Highlight Filters window.")
    }
}
