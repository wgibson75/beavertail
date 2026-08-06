//
//  MenuUITests.swift
//  BeaverTailUITests
//
//  Tier 2: menu-bar command presence and the ⌘S "Save to File…" enablement wiring.
//

import XCTest

final class MenuUITests: BeaverTailUITestCase {

    func testCoreMenuCommandsPresent() {
        let app = launchApp()
        let menuBar = app.menuBars

        menuBar.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["Open…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Open Recent"].exists)
        XCTAssertTrue(app.menuItems["Save to File…"].exists)
        app.typeKey(.escape, modifierFlags: [])

        menuBar.menuBarItems["BeaverTail"].click()
        XCTAssertTrue(app.menuItems["Install btail CLI"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Check for Updates…"].exists)
        app.typeKey(.escape, modifierFlags: [])

        menuBar.menuBarItems["Help"].click()
        XCTAssertTrue(app.menuItems["BeaverTail Help"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSaveToFileDisabledWithoutUniqueLinesTab() {
        let app = launchApp()
        app.menuBars.menuBarItems["File"].click()
        let save = app.menuItems["Save to File…"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled,
                       "'Save to File…' must be disabled until the unique-lines results tab is active.")
        app.typeKey(.escape, modifierFlags: [])
    }
}
