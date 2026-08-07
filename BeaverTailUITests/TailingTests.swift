//
//  TailingTests.swift
//  BeaverTailUITests
//
//  Verifies that BeaverTail's live-tailing (Follow) keeps the minimap and the
//  Timeline View correctly summarising a log file that is actively being appended
//  to. The log is driven by `LogFeeder` (a self-contained Swift port of
//  `scripts/writelog.py`) at up to the target 250 KB/s, and the highlight filters
//  are injected per-launch so the tests never depend on the developer's own saved
//  configuration.
//
//  These three cases are intentionally a foundation to be extended: they establish
//  the live-feed harness, the self-contained highlight-filter injection, and the
//  accessibility probe that make richer tailing assertions possible later.
//

import XCTest

final class TailingTests: BeaverTailUITestCase {

    // Unique tokens that do NOT appear in `LogFeeder`'s word pool, so a highlight
    // filter for each matches ONLY the marker lines the test injects — making
    // highlight-match and Timeline-heading growth deterministic.
    private let markerA = "ZEBRA"
    private let markerB = "QUOKKA"
    private let markerC = "NARWHAL"
    private let markerD = "AXOLOTL"

    /// A self-contained set of four highlight filters, one per marker token.
    private var highlightSpecs: [HighlightFilterSpec] {
        [
            HighlightFilterSpec(pattern: markerA, background: "#E53935"),
            HighlightFilterSpec(pattern: markerB, background: "#43A047"),
            HighlightFilterSpec(pattern: markerC, background: "#1E88E5"),
            HighlightFilterSpec(pattern: markerD, background: "#8E24AA")
        ]
    }

    /// A small seed so the tab loads with real content before tailing begins.
    private func seedLog() -> URL {
        var text = ""
        for i in 0..<20 { text += "[startup] baseline line \(i)\n" }
        return makeTempLog(text)
    }

    // MARK: - 1. Minimap tailing

    /// With Follow on, the minimap must keep summarising the log as it grows, and
    /// reflect highlighted entries as lines matching the filters are appended.
    func testMinimapTailing() {
        let log = seedLog()
        let app = launchApp(
            openingFiles: [log],
            showMinimap: true,
            showTimeline: false,
            highlightRules: highlightSpecs
        )

        // Wait for the seed content to load, then start following.
        let seeded = waitForProbe("probe.totalLineCount", in: app, timeout: 20) { $0 >= 20 }
        XCTAssertGreaterThanOrEqual(seeded, 20, "Seed log should have loaded before tailing.")
        enableFollow(in: app)

        let feeder = LogFeeder(fileURL: log)
        defer { feeder.stop() }
        feeder.start(bytesPerSecond: 250 * 1024)

        // The minimap must render a bitmap summary of the (growing) log…
        let minimapReady = waitForProbe("probe.minimapRendered", in: app, timeout: 25) { $0 == 1 }
        XCTAssertEqual(minimapReady, 1, "The minimap should render while tailing.")

        // …and keep growing as new lines stream in (live-tail summary is updating).
        let grown = waitForProbe("probe.totalLineCount", in: app, timeout: 30) { $0 >= seeded + 200 }
        XCTAssertGreaterThanOrEqual(
            grown, seeded + 200,
            "The minimap-backed log should keep ingesting appended lines while following."
        )

        // Inject lines that match two of the highlight filters, so the minimap has
        // highlighted entries to summarise.
        for _ in 0..<8 {
            feeder.emitLineContaining(markerA)
            feeder.emitLineContaining(markerB)
        }
        let highlighted = waitForProbe("probe.highlightMatchCount", in: app, timeout: 25) { $0 >= 6 }
        XCTAssertGreaterThanOrEqual(
            highlighted, 6,
            "The minimap should reflect highlighted entries as matching lines are tailed."
        )
    }

    // MARK: - 2. Timeline View tailing

    /// With Follow on and a filter applied, the Timeline View must show the correct
    /// headings, and its heading count must grow as newly-tailed lines start matching
    /// additional highlight filters.
    func testTimelineViewTailing() {
        let log = seedLog()
        let app = launchApp(
            openingFiles: [log],
            showMinimap: false,
            showTimeline: true,
            highlightRules: highlightSpecs
        )

        let seeded = waitForProbe("probe.totalLineCount", in: app, timeout: 20) { $0 >= 20 }
        XCTAssertGreaterThanOrEqual(seeded, 20, "Seed log should have loaded before tailing.")

        enableFollow(in: app)
        // The Timeline only shows entries (and headings) when a regex filter is
        // applied. Filter on the "MARKER" sentinel that appears ONLY in the injected
        // marker lines (never in the volume stream). This keeps the filtered set tiny
        // and stable, so each Timeline re-render during tailing is cheap and completes
        // promptly. (A match-everything filter like "." makes the Timeline re-render
        // the entire, ever-growing filtered set on every 200 ms tail batch; at
        // 250 KB/s those renders get cancelled before finishing, so the pane sticks on
        // "Processing highlight filters…" and the heading count lags.)
        applyFilter("MARKER", in: app)

        let feeder = LogFeeder(fileURL: log)
        defer { feeder.stop() }
        feeder.start(bytesPerSecond: 250 * 1024)

        // First prove the tab ingests appended lines while following under load…
        let grown = waitForProbe("probe.totalLineCount", in: app, timeout: 30) { $0 >= seeded + 200 }
        XCTAssertGreaterThanOrEqual(
            grown, seeded + 200,
            "The filtered log should keep ingesting appended lines while following."
        )

        // …then STOP the high-rate volume flood. Continuing to stream at 250 KB/s for
        // the whole test grows the log to many megabytes, and every XCUITest snapshot
        // (each probe read and the final heading lookup) then has to serialise an
        // ever-larger accessibility tree — snapshots balloon from milliseconds to many
        // seconds, so the per-marker `waitForProbe` calls and the final
        // `waitForExistence` time out (the test then fails consistently on slower
        // machines). The volume stream has done its job; quiescing it keeps the tree
        // small so the heading assertions below are fast and deterministic. Markers are
        // still appended to the same file and picked up by live tailing, so heading
        // growth is genuinely driven by newly-tailed lines.
        feeder.stopVolumeStream()

        // Each injected marker line contains "MARKER" (so it passes the filter) plus a
        // unique token matched by one highlight filter. No volume-stream line matches
        // either, so the Timeline starts with zero headings; introduce the markers one
        // at a time and assert the heading count grows to include each new rule.
        introduce(marker: markerA, feeder: feeder)
        let after1 = waitForProbe("probe.timelineHeadingCount", in: app, timeout: 30) { $0 >= 1 }
        XCTAssertGreaterThanOrEqual(after1, 1, "First matching filter should add a Timeline heading.")

        introduce(marker: markerB, feeder: feeder)
        let after2 = waitForProbe("probe.timelineHeadingCount", in: app, timeout: 30) { $0 >= 2 }
        XCTAssertGreaterThanOrEqual(after2, 2, "Second matching filter should grow the headings.")

        introduce(marker: markerC, feeder: feeder)
        let after3 = waitForProbe("probe.timelineHeadingCount", in: app, timeout: 30) { $0 >= 3 }
        XCTAssertGreaterThanOrEqual(after3, 3, "Third matching filter should grow the headings.")

        introduce(marker: markerD, feeder: feeder)
        let after4 = waitForProbe("probe.timelineHeadingCount", in: app, timeout: 30) { $0 >= 4 }
        XCTAssertGreaterThanOrEqual(after4, 4, "Fourth matching filter should grow the headings.")

        // The Timeline must have rendered its summary bitmap for the matched entries…
        let rendered = waitForProbe("probe.timelineRendered", in: app, timeout: 20) { $0 == 1 }
        XCTAssertEqual(rendered, 1, "The Timeline should render once entries match the filters.")

        // …and the growth must be monotonic across the four phases.
        XCTAssertTrue(
            after1 <= after2 && after2 <= after3 && after3 <= after4,
            "Timeline heading count should only grow as more filters match "
            + "(saw \(after1), \(after2), \(after3), \(after4))."
        )

        // Sanity: the real Timeline heading controls are present in the UI too.
        XCTAssertTrue(
            element("timelineHeading", in: app).waitForExistence(timeout: 10),
            "At least one real Timeline heading control should be shown."
        )
    }

    // MARK: - 3. Selecting a region of the log on the minimap whilst tailing

    /// With Follow on and the minimap shown, dragging out a region on the minimap must
    /// mark out a time period — hiding every line outside it — *whilst the log is still
    /// being tailed*. The narrowed range must HOLD as new lines continue to stream in
    /// (they fall beyond the region, so they stay hidden and the visible subset does not
    /// grow). Then, with a filter applied, clicking an entry on the (region-restricted)
    /// minimap must jump to that line and SELECT it in the bottom (filtered) pane.
    /// Finally, the Reset control must reveal the full log again.
    func testMinimapRegionSelectionWhileTailing() {
        let log = seedLog()
        let app = launchApp(
            openingFiles: [log],
            showMinimap: true,
            showTimeline: false,
            highlightRules: highlightSpecs
        )

        let seeded = waitForProbe("probe.totalLineCount", in: app, timeout: 20) { $0 >= 20 }
        XCTAssertGreaterThanOrEqual(seeded, 20, "Seed log should have loaded before tailing.")
        enableFollow(in: app)

        let feeder = LogFeeder(fileURL: log)
        defer { feeder.stop() }
        // Cap the volume so the log stays small and its size is predictable (the probe
        // waits are snapshot-latency-bound, so an uncapped 250 KB/s flood would append a
        // large, variable number of lines). A bounded volume keeps the ZEBRA cluster the
        // dominant part of the log so the region below is entirely filtered lines, and
        // keeps the accessibility tree small so the test stays fast.
        let volumeCap = 500
        feeder.start(bytesPerSecond: 250 * 1024, maxLines: volumeCap)

        // The minimap must render while tailing, and the log must grow enough that a
        // dragged region carves out a clearly-smaller subset.
        let minimapReady = waitForProbe("probe.minimapRendered", in: app, timeout: 25) { $0 == 1 }
        XCTAssertEqual(minimapReady, 1, "The minimap should render while tailing.")
        let grown = waitForProbe("probe.totalLineCount", in: app, timeout: 30) { $0 >= seeded + 400 }
        XCTAssertGreaterThanOrEqual(
            grown, seeded + 400,
            "The log should ingest appended lines while following, before selecting a region."
        )

        // The volume stream self-terminates at `volumeCap`; wait for the tail to exit so
        // the marker lines injected next are guaranteed to be the LAST lines in the file.
        feeder.stopVolumeStream()

        // Inject a LARGE cluster of markerA ("ZEBRA") lines at the tail — more than the
        // capped volume — so they dominate the log and sit contiguously at the very end.
        // A region carved from the bottom then consists ENTIRELY of ZEBRA (filtered)
        // lines, so any minimap click there lands on a filtered line (no need to hit a
        // pixel-thin highlight band).
        let zebraBatch = 800
        for _ in 0..<zebraBatch { feeder.emitLineContaining(markerA) }
        let fullCount = waitForProbe("probe.totalLineCount", in: app, timeout: 20) { $0 >= grown + zebraBatch }
        XCTAssertGreaterThanOrEqual(fullCount, grown + zebraBatch, "The marker cluster should have been tailed in.")

        // Filter on markerA so the bottom pane shows exactly the ZEBRA cluster.
        applyFilter(markerA, in: app)

        XCTAssertEqual(
            probeInt("probe.isHidingLines", in: app), 0,
            "No lines should be hidden before a region is selected."
        )

        // Drag out the BOTTOM half of the minimap (a large, reliable drag). Because the
        // ZEBRA cluster (\(zebraBatch) lines) is larger than the capped volume, the whole
        // bottom half falls inside it — every visible line is a ZEBRA line.
        selectMinimapRegion(fromFraction: 0.5, toFraction: 1.0, in: app)

        // The tab must now be hiding lines outside the region…
        let hiding = waitForProbe("probe.isHidingLines", in: app, timeout: 20) { $0 == 1 }
        XCTAssertEqual(hiding, 1, "Dragging out a minimap region should hide lines outside it.")

        // …restricting the visible set to a proper subset of the full log.
        let visible = waitForProbe("probe.visibleLineCount", in: app, timeout: 20) { $0 > 0 && $0 < fullCount }
        XCTAssertTrue(
            visible > 0 && visible < fullCount,
            "The visible set (\(visible)) should be a proper subset of the full log (\(fullCount))."
        )

        // Selecting whilst tailing must HOLD: keep appending non-matching lines (markerB);
        // their indices are beyond the region's upper bound, so the total keeps climbing
        // while the visible subset stays unchanged.
        let totalBefore = probeInt("probe.totalLineCount", in: app) ?? fullCount
        for _ in 0..<40 { feeder.emitLineContaining(markerB) }
        let totalAfter = waitForProbe("probe.totalLineCount", in: app, timeout: 20) { $0 > totalBefore }
        XCTAssertGreaterThan(
            totalAfter, totalBefore,
            "Live tailing should continue after a region is selected."
        )
        XCTAssertEqual(
            probeInt("probe.isHidingLines", in: app), 1,
            "The selected region should persist while tailing continues."
        )
        XCTAssertEqual(
            probeInt("probe.visibleLineCount", in: app), visible,
            "Newly-tailed lines beyond the region stay hidden, so the visible subset is unchanged."
        )

        // Click an entry in the MIDDLE of the (region-restricted) minimap. Every visible
        // line is a ZEBRA line in the bottom pane's filtered set, so the jump must SELECT
        // a filtered line in the bottom pane.
        clickMinimap(atFraction: 0.5, in: app)
        let jumped = waitForProbe("probe.bottomPaneSelectedOriginal", in: app, timeout: 20) { $0 >= 0 }
        XCTAssertGreaterThanOrEqual(
            jumped, 0,
            "Clicking a minimap entry should jump to a filtered line in the bottom pane."
        )
        XCTAssertGreaterThanOrEqual(
            jumped, fullCount - zebraBatch,
            "The jump should land on one of the ZEBRA cluster lines at the tail of the region."
        )
        XCTAssertEqual(
            probeInt("probe.selectedOriginalIndex", in: app), jumped,
            "The top-pane current line should match the filtered line jumped to."
        )

        // The Reset control is offered once a subset is shown; using it reveals all
        // lines again (isHidingLines clears and the visible set returns to the full log).
        let reset = element("resetHiddenLinesButton", in: app)
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "The Reset (show all lines) control should appear.")
        reset.click()
        let revealed = waitForProbe("probe.isHidingLines", in: app, timeout: 20) { $0 == 0 }
        XCTAssertEqual(revealed, 0, "Resetting should reveal all lines again.")
    }

    // MARK: - Helpers

    /// Emits a short burst of a marker token so its highlight filter reliably starts
    /// matching within the continuously-generated volume stream.
    private func introduce(marker: String, feeder: LogFeeder) {
        for _ in 0..<4 { feeder.emitLineContaining(marker) }
    }
}
