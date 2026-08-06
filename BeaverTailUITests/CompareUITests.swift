//
//  CompareUITests.swift
//  BeaverTailUITests
//
//  Tier 4: the mark → compare → results workflow, driven through the real tab
//  context menu. Complements the unit-level `CompareTests` by proving the wiring.
//

import XCTest

final class CompareUITests: BeaverTailUITestCase {

    // MARK: - T4.1 Marking a tab reflects in its menu.

    func testMarkingTabRevealsClearItems() {
        let log = makeTempLog("shared line\nonly here")
        let app = launchApp(openingFiles: [log])
        let name = log.lastPathComponent

        openTabContextMenu(fileName: name, in: app)
        XCTAssertTrue(app.menuItems["Mark as Good"].waitForExistence(timeout: 5))
        // Before marking, the Clear items are absent.
        XCTAssertFalse(app.menuItems["Clear All"].exists)
        app.menuItems["Mark as Good"].click()

        // Reopen the menu: marking the tab reveals "Clear" and "Clear All".
        openTabContextMenu(fileName: name, in: app)
        XCTAssertTrue(app.menuItems["Clear"].waitForExistence(timeout: 5),
                      "Marking a tab should reveal the Clear item.")
        XCTAssertTrue(app.menuItems["Clear All"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - T4.2 Comparison commands are gated by having a Good and a Bad.

    func testComparisonCommandsGatedByMarks() {
        let good = makeTempLog("shared\nonly-good")
        let bad = makeTempLog("shared\nonly-bad")
        let app = launchApp(openingFiles: [good, bad])
        let goodName = good.lastPathComponent
        let badName = bad.lastPathComponent

        // No marks yet → comparison commands absent.
        openTabContextMenu(fileName: goodName, in: app)
        XCTAssertTrue(app.menuItems["Mark as Good"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Show Unique Lines from Bad"].exists)
        app.menuItems["Mark as Good"].click()

        // Only a Good marked → still gated.
        openTabContextMenu(fileName: goodName, in: app)
        XCTAssertFalse(app.menuItems["Show Unique Lines from Bad"].exists,
                       "Comparison needs both a Good and a Bad log.")
        app.typeKey(.escape, modifierFlags: [])

        // Mark the other as Bad → commands appear.
        openTabContextMenu(fileName: badName, in: app)
        app.menuItems["Mark as Bad"].click()
        openTabContextMenu(fileName: badName, in: app)
        XCTAssertTrue(app.menuItems["Show Unique Lines from Bad"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Show Unique Lines from Good"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - T4.3 End-to-end unique lines creates a results tab and enables Save.

    func testUniqueLinesCreatesResultsTabAndEnablesSave() {
        let good = makeTempLog("shared\nonly-good")
        let bad = makeTempLog("shared\nonly-bad")
        let app = launchApp(openingFiles: [good, bad])

        openTabContextMenu(fileName: good.lastPathComponent, in: app)
        app.menuItems["Mark as Good"].click()
        openTabContextMenu(fileName: bad.lastPathComponent, in: app)
        app.menuItems["Mark as Bad"].click()

        openTabContextMenu(fileName: bad.lastPathComponent, in: app)
        let showBad = app.menuItems["Show Unique Lines from Bad"]
        XCTAssertTrue(showBad.waitForExistence(timeout: 5))
        showBad.click()

        // A synthetic "unique-lines.txt" results tab appears.
        XCTAssertTrue(app.staticTexts["unique-lines.txt"].waitForExistence(timeout: 20),
                      "A unique-lines results tab should be created.")

        // With that tab active, File ▸ Save to File… becomes enabled.
        XCTAssertTrue(waitUntil(timeout: 10) {
            app.menuBars.menuBarItems["File"].click()
            let save = app.menuItems["Save to File…"]
            let enabled = save.exists && save.isEnabled
            app.typeKey(.escape, modifierFlags: [])
            return enabled
        }, "Save to File… should become enabled once the unique-lines tab is active.")
    }
}
