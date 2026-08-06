//
//  TabManagementUITests.swift
//  BeaverTailUITests
//
//  Tier 8: opening multiple files creates tabs, selecting switches content, and
//  ⌘W closes the active tab (rather than the window), returning to the empty
//  state once the last tab is closed.
//

import XCTest

final class TabManagementUITests: BeaverTailUITestCase {

    func testMultipleFilesCreateTabsAndCommandWClosesActiveTab() {
        let first = makeTempLog("first-only")
        let second = makeTempLog("second-only")
        let app = launchApp(openingFiles: [first, second])
        let firstTab = element("logTab-\(first.lastPathComponent)", in: app)
        let secondTab = element("logTab-\(second.lastPathComponent)", in: app)

        XCTAssertTrue(firstTab.waitForExistence(timeout: 20), "First tab should exist.")
        XCTAssertTrue(secondTab.waitForExistence(timeout: 20), "Second tab should exist.")

        // Select the first tab and confirm its content is shown.
        firstTab.click()
        XCTAssertTrue(app.staticTexts["first-only"].waitForExistence(timeout: 10),
                      "Selecting a tab should show that file's content.")

        // ⌘W closes the active (first) tab, leaving the second and the window intact.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(firstTab.waitForNonExistence(timeout: 10),
                      "⌘W should close the active tab.")
        XCTAssertTrue(secondTab.exists, "The other tab should remain open.")
        XCTAssertTrue(app.windows.firstMatch.exists, "The window should stay open.")
    }

    func testClosingLastTabReturnsToEmptyState() {
        let only = makeTempLog("sole content")
        let app = launchApp(openingFiles: [only])
        let tab = element("logTab-\(only.lastPathComponent)", in: app)
        XCTAssertTrue(tab.waitForExistence(timeout: 20))

        // Focus the tab, then close it with ⌘W. Retry the keystroke a couple of times
        // in case the first doesn't route while the window is settling.
        tab.click()
        let emptyState = app.staticTexts["No Log File Open"]
        var appeared = false
        for _ in 0..<3 where !appeared {
            app.typeKey("w", modifierFlags: .command)
            appeared = emptyState.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(appeared, "Closing the last tab should return to the empty state.")
    }
}
