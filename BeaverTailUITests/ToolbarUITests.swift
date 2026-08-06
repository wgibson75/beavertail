//
//  ToolbarUITests.swift
//  BeaverTailUITests
//
//  Tier 7: toolbar view toggles flip state, and the font-size stepper updates its
//  label and respects the 8–24pt bounds.
//

import XCTest

final class ToolbarUITests: BeaverTailUITestCase {

    // MARK: - T7.1 View toggles flip on/off.

    func testViewTogglesFlipState() {
        let log = makeTempLog("a\nb\nc")
        let app = launchApp(openingFiles: [log])
        XCTAssertTrue(app.staticTexts[log.lastPathComponent].waitForExistence(timeout: 20))

        for id in ["minimapToggle", "timelineToggle", "lineNumbersToggle"] {
            let toggle = element(id, in: app)
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), "\(id) should exist.")
            let initial = isOn(toggle)
            toggle.click()
            XCTAssertTrue(waitUntil(timeout: 5) { isOn(toggle) != initial },
                          "\(id) should flip its state when clicked.")
            toggle.click()
            XCTAssertTrue(waitUntil(timeout: 5) { isOn(toggle) == initial },
                          "\(id) should flip back when clicked again.")
        }
    }

    // MARK: - T7.2 Font stepper updates the label and honours the bounds.

    func testFontStepperUpdatesLabelAndClampsAtBounds() {
        let log = makeTempLog("a\nb")
        let app = launchApp(openingFiles: [log])
        XCTAssertTrue(app.staticTexts[log.lastPathComponent].waitForExistence(timeout: 20))

        let inc = element("fontIncreaseButton", in: app)
        let dec = element("fontDecreaseButton", in: app)
        XCTAssertTrue(inc.waitForExistence(timeout: 10))

        // The label is exposed via its `value` (e.g. "12pt"), located by identifier.
        let ptLabel = element("fontSizeLabel", in: app)
        XCTAssertTrue(ptLabel.waitForExistence(timeout: 10), "The 'Npt' label should exist.")
        func ptValue() -> String { (ptLabel.value as? String) ?? "" }

        let before = ptValue()
        inc.click()
        XCTAssertTrue(waitUntil(timeout: 5) { ptValue() != before },
                      "Increasing the font size should update the label.")
        let increased = ptValue()
        dec.click()
        XCTAssertTrue(waitUntil(timeout: 5) { ptValue() != increased },
                      "Decreasing the font size should update the label.")

        // Clamp at the maximum: click increase until disabled; it must never exceed 24pt.
        var guardCount = 0
        while inc.isEnabled && guardCount < 40 {
            inc.click()
            guardCount += 1
        }
        XCTAssertEqual(ptValue(), "24pt", "Font size should clamp at 24pt.")
        XCTAssertFalse(inc.isEnabled, "The increase button should disable at the maximum.")
    }
}
