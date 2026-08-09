//
//  TimelineProgressiveReproTests.swift
//  BeaverTailTests
//
//  Verifies the Timeline renders progressively (coloured entries appear while
//  "Processing highlight filters…" is still running) on a very large log. Gated on
//  the file existing so it never runs in CI. Invoke with:
//    -only-testing:BeaverTailTests/TimelineProgressiveReproTests
//

import XCTest
@testable import BeaverTail

@MainActor
final class TimelineProgressiveReproTests: XCTestCase {

    private let path = "/Users/wigibson/Downloads/test.log"

    func testTimelineRendersProgressivelyDuringHighlightScan() throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("huge log not present at \(path)")
        }
        let defaults = PersistedDefaults.clear()
        defer { PersistedDefaults.restore(defaults) }

        let viewModel = LogViewModel()
        viewModel.showTimeline = true
        let patterns = ["ERROR", "success", "timeout", "database", "pool", "connection",
                        "committed", "gateway", "cpu", "transaction", "response", "warning"]
        viewModel.highlightRulesStore.rules = patterns.map {
            HighlightRule(pattern: $0, foregroundColorHex: "#000000", backgroundColorHex: "#FFFF00",
                          isCaseSensitive: false, isEnabled: true, groupID: nil)
        }

        viewModel.loadNewTab(from: URL(fileURLWithPath: path))
        guard let tabID = viewModel.selectedTabID else { return XCTFail("no tab") }
        // A filter that matches many lines (Timeline only renders for a filtered view).
        viewModel.applyFilter(with: "pool")

        func tab() -> LogTab? { viewModel.openTabs.first { $0.id == tabID } }

        let start = DispatchTime.now().uptimeNanoseconds
        var timelineUpdatesDuringProcessing = 0
        var firstImageDuringProcessingMs: Double?
        var lastImageID: ObjectIdentifier?
        var bannerClearedMs: Double?
        var firstHeadingsMs: Double?
        let exp = expectation(description: "scan completes")

        func poll() {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let t = tab()
            let processing = t?.isProcessingHighlights ?? false
            if firstHeadingsMs == nil, (t?.timelineActiveRuleIDs.count ?? 0) > 0 {
                firstHeadingsMs = ms
            }
            if let image = viewModel.timelineImageByTab[tabID] {
                let idNow = ObjectIdentifier(image)
                if idNow != lastImageID {
                    lastImageID = idNow
                    if processing {
                        timelineUpdatesDuringProcessing += 1
                        if firstImageDuringProcessingMs == nil { firstImageDuringProcessingMs = ms }
                    }
                }
            }
            let streamingDone = (t?.isCurrentlyStreaming == false)
            if streamingDone, !processing, bannerClearedMs == nil, (t?.highlightMatches.reduce(0) { $0 + $1.count } ?? 0) > 0 {
                bannerClearedMs = ms
                exp.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { poll() }
        }
        poll()
        wait(for: [exp], timeout: 420)
        viewModel.stopLiveTailing()

        print(String(format: "[timeline] updates-during-processing=%d  firstImage@=%@ms  firstHeadings@=%@ms  bannerCleared@=%.0fms",
                     timelineUpdatesDuringProcessing,
                     firstImageDuringProcessingMs.map { String(format: "%.0f", $0) } ?? "never",
                     firstHeadingsMs.map { String(format: "%.0f", $0) } ?? "never",
                     bannerClearedMs ?? -1))
        // The Timeline must render coloured entries (and their headings) progressively
        // while highlights are still processing — appearing well before the scan
        // completes — rather than only at the very end.
        XCTAssertGreaterThan(timelineUpdatesDuringProcessing, 3,
                             "Timeline should render repeatedly WHILE highlights are still processing")
        if let first = firstImageDuringProcessingMs, let cleared = bannerClearedMs {
            XCTAssertLessThan(first, cleared * 0.75,
                              "First coloured Timeline entry should appear well before processing completes")
        } else {
            XCTFail("No Timeline image appeared during processing")
        }
    }
}
