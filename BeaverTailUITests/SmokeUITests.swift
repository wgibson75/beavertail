//
//  SmokeUITests.swift
//  BeaverTailUITests
//
//  Tier 1: launch / empty-state smoke and the core "open a file shows content" flow.
//

import XCTest

final class SmokeUITests: BeaverTailUITestCase {

    func testLaunchShowsEmptyState() {
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["No Log File Open"].waitForExistence(timeout: 20),
                      "The empty-state prompt should appear on a clean launch.")
        // Match the button by its title: on macOS SwiftUI exposes a titled Button as
        // an AXButton keyed on its label, which is the reliable handle here.
        XCTAssertTrue(app.buttons["Open Log File…"].waitForExistence(timeout: 5),
                      "The empty-state 'Open Log File…' button should be present.")
    }

    func testLaunchingWithFileShowsContent() {
        let url = makeTempLog("alpha line\nbeta line\ngamma line")
        let app = launchApp(openingFiles: [url])

        // The tab label carries the opened file's name.
        XCTAssertTrue(app.staticTexts[url.lastPathComponent].waitForExistence(timeout: 20),
                      "A tab for the opened file should appear.")
        // The empty state must have been replaced by the log view.
        XCTAssertFalse(app.staticTexts["No Log File Open"].exists,
                       "The empty state should be gone once a file is open.")
    }
}
