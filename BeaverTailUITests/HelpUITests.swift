//
//  HelpUITests.swift
//  BeaverTailUITests
//
//  Tier 10: the Help sheet opens from the Help menu and its search box filters the
//  topics (an unmatched query shows the "no topics" message).
//

import XCTest

final class HelpUITests: BeaverTailUITestCase {

    func testHelpOpensAndSearchFiltersTopics() {
        let app = launchApp()

        // The Help panel is a SwiftUI `.sheet`, which only presents when its owning
        // window is key. Ensure the app/window is frontmost, then trigger Help — and
        // retry the trigger if the sheet doesn't appear (e.g. the window wasn't yet
        // key when the menu action fired on a slower host).
        let header = app.staticTexts["BeaverTail Help"]
        var presented = false
        for _ in 0..<3 where !presented {
            bringToForeground(app)
            app.menuBars.menuBarItems["Help"].click()
            let helpItem = app.menuItems["BeaverTail Help"]
            XCTAssertTrue(helpItem.waitForExistence(timeout: 5))
            helpItem.click()
            presented = header.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(presented, "The Help sheet should present its header.")

        let search = app.textFields["Search Help"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "The Help search field should exist.")

        // Focus the field and type a term that matches nothing. Retry the click/type
        // if focus didn't take (SwiftUI sheet fields can need a second click).
        XCTAssertTrue(waitUntil(timeout: 8) {
            search.click()
            search.typeText("zzzznotopic")
            return app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS 'No help topics match' OR value CONTAINS 'No help topics match'"))
                .firstMatch.exists
        }, "An unmatched search should show the no-topics message.")
    }
}
