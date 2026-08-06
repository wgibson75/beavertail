//
//  TimelineOverlayUITests.swift
//  BeaverTailUITests
//
//  Tier 9: the Timeline "Processing highlight filters…" overlay. Regression guard
//  for the overlay work. The overlay is transient, so catching its appearance is
//  best-effort — but the test always enforces the important invariant: it must
//  never get stuck on screen once reprocessing settles.
//

import XCTest

final class TimelineOverlayUITests: BeaverTailUITestCase {

    private let processingText = "Processing highlight filters…"

    func testProcessingOverlayNeverStuckAfterFilterChange() {
        // A larger log makes reprocessing observable rather than instant.
        let log = makeGeneratedLog(lineCount: 200_000)
        let app = launchApp(openingFiles: [log])
        XCTAssertTrue(app.staticTexts[log.lastPathComponent].waitForExistence(timeout: 40))

        // Enable the Timeline pane.
        let timeline = element("timelineToggle", in: app)
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        if !timeline.isSelected { timeline.click() }

        // Apply an initial filter to build a Timeline (entries only show with a
        // filter), then wait for the empty-filter prompt to clear.
        applyFilter("alpha", in: app)
        _ = waitUntil(timeout: 30) {
            !app.staticTexts["Enter a regex pattern above to filter log lines"].exists
        }

        // Re-apply a different filter: this reprocesses while the prior Timeline
        // image is retained, which is when the floating overlay is shown.
        applyFilter("beta", in: app)

        // Best-effort: if we catch the overlay, it must clear again.
        let overlay = app.staticTexts[processingText]
        if overlay.waitForExistence(timeout: 5) {
            XCTAssertTrue(overlay.waitForNonExistence(timeout: 40),
                          "The processing overlay must clear once reprocessing completes.")
        }

        // Invariant regardless of timing: the overlay must not be stuck on screen.
        XCTAssertTrue(waitUntil(timeout: 40) { !overlay.exists },
                      "The processing overlay must not remain after reprocessing settles.")
    }
}
