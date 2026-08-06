//
//  LogComparisonServiceTests.swift
//  BeaverTailTests
//
//  Item 1: signature + unique-line logic (pure, self-contained).
//

import XCTest
@testable import BeaverTail

@MainActor
final class LogComparisonServiceTests: XCTestCase {

    // MARK: - signature(for:) — Happy path

    func testSignatureRemovesHexDigits() {
        // '1' and '2' are hex and removed; 'G' is not hex and kept.
        XCTAssertEqual(LogComparisonService.signature(for: "G12"), "G")
    }

    func testSignatureRemovesHexLetters() {
        // 'e' is a hex letter (a-f) and is removed.
        XCTAssertEqual(LogComparisonService.signature(for: "hello"), "hllo")
    }

    func testSignatureRemovesDoubleQuotedSpanWholesale() {
        XCTAssertEqual(LogComparisonService.signature(for: "p\"Q\"r"), "pr")
    }

    func testSignatureRemovesSingleQuotedSpanWholesale() {
        XCTAssertEqual(LogComparisonService.signature(for: "x'abc'y"), "xy")
    }

    func testTwoLinesDifferingOnlyByVolatilePartsCollapse() {
        let first = LogComparisonService.signature(for: "grok 0x1F3 running")
        let second = LogComparisonService.signature(for: "grok 0xAB9 running")
        XCTAssertEqual(first, second)
    }

    // MARK: - signature(for:) — Edge cases & Boundaries

    func testSignatureOfEmptyStringIsEmpty() {
        XCTAssertEqual(LogComparisonService.signature(for: ""), "")
    }

    func testUnmatchedQuoteIsKeptAndScanningContinues() {
        // No closing quote: the delimiter is kept and following non-hex chars remain.
        // 'z' is deliberately not a hex letter, so it survives alongside the quote.
        XCTAssertEqual(LogComparisonService.signature(for: "z'xy"), "z'xy")
    }

    func testHexLetterBoundaries() {
        // a-f / A-F are hex (removed); g/G and non-hex letters are kept.
        XCTAssertEqual(LogComparisonService.signature(for: "gG fF"), "gG ")
    }

    func testNonASCIICharactersAreRetained() {
        XCTAssertEqual(LogComparisonService.signature(for: "é1"), "é")
    }

    // MARK: - uniqueLines — Happy path

    func testUniqueLinesReturnsSourceOnlyFlavours() {
        let sources = [makeComparisonSource(["grok 1", "spin 2"])]
        let others = [makeComparisonSource(["grok 9"])]
        let result = LogComparisonService.uniqueLines(in: sources, notIn: others)
        XCTAssertEqual(result, ["spin 2"])
    }

    func testSourceBucketIsIntersectionAcrossAllSourceLogs() {
        // "grok" appears in both source logs; "spin"/"trip" only in one each, so only
        // the common flavour survives the intersection.
        let sources = [
            makeComparisonSource(["grok 1", "spin 1"]),
            makeComparisonSource(["grok 2", "trip 2"])
        ]
        let result = LogComparisonService.uniqueLines(in: sources, notIn: [])
        XCTAssertEqual(result, ["grok 1"])
    }

    func testReferenceBucketIsUnionAcrossAllReferenceLogs() {
        let sources = [makeComparisonSource(["grok 1", "spin 1", "trip 1"])]
        let others = [
            makeComparisonSource(["grok 2"]),
            makeComparisonSource(["spin 2"])
        ]
        let result = LogComparisonService.uniqueLines(in: sources, notIn: others)
        XCTAssertEqual(result, ["trip 1"])
    }

    func testResultsEmittedFromFirstSourceInOriginalOrder() {
        let sources = [makeComparisonSource(["trip 1", "grok 1", "spin 1"])]
        let result = LogComparisonService.uniqueLines(in: sources, notIn: [])
        XCTAssertEqual(result, ["trip 1", "grok 1", "spin 1"])
    }

    // MARK: - uniqueLines — Edge cases & Boundaries

    func testEmptySourcesReturnsEmpty() {
        let others = [makeComparisonSource(["grok 1"])]
        XCTAssertEqual(LogComparisonService.uniqueLines(in: [], notIn: others), [])
    }

    func testEmptyReferenceReturnsAllDistinctSourceLines() {
        let sources = [makeComparisonSource(["grok 1", "spin 1"])]
        let result = LogComparisonService.uniqueLines(in: sources, notIn: [])
        XCTAssertEqual(result, ["grok 1", "spin 1"])
    }

    func testExactDuplicateLinesAreCollapsed() {
        let sources = [makeComparisonSource(["grok 1", "grok 1", "spin 1"])]
        let result = LogComparisonService.uniqueLines(in: sources, notIn: [])
        XCTAssertEqual(result, ["grok 1", "spin 1"])
    }

    func testDistinctLinesSharingUniqueSignatureAreAllShown() {
        // "grok 1" and "grok 2" reduce to the same signature but are distinct lines,
        // so both are emitted.
        let sources = [makeComparisonSource(["grok 1", "grok 2"])]
        let result = LogComparisonService.uniqueLines(in: sources, notIn: [])
        XCTAssertEqual(result, ["grok 1", "grok 2"])
    }

    // MARK: - uniqueLines — Failure modes

    func testCancellationYieldsEmptyResult() {
        let sources = [makeComparisonSource(["grok 1", "spin 1"])]
        let others = [makeComparisonSource(["grok 9"])]
        let result = LogComparisonService.uniqueLines(
            in: sources, notIn: others, isCancelled: { true }
        )
        XCTAssertEqual(result, [])
    }

    // MARK: - uniqueLines — State / Concurrency

    func testLargeInputMatchesSingleThreadedReference() {
        // Exceeds the 8192-line chunk size so the parallel path and chunk merge run.
        let count = 20_000
        var sourceLines: [String] = []
        sourceLines.reserveCapacity(count)
        for i in 0..<count {
            // Every third line is a unique "spin" flavour; the rest are "grok".
            sourceLines.append(i % 3 == 0 ? "spin \(i)" : "grok \(i)")
        }
        let sources = [makeComparisonSource(sourceLines)]
        // Reference contains a grok flavour, so all grok lines are "normal".
        let others = [makeComparisonSource(["grok 0"])]

        let result = LogComparisonService.uniqueLines(in: sources, notIn: others)

        // Expected: every distinct spin line, in order.
        let expected = sourceLines.filter { $0.hasPrefix("spin") }
        XCTAssertEqual(result, expected)
    }

    func testProgressIsReportedDuringComparison() {
        let sources = [makeComparisonSource(["grok 1", "spin 1"])]
        let others = [makeComparisonSource(["grok 9"])]
        let progress = ScanProgress(total: 3)
        _ = LogComparisonService.uniqueLines(in: sources, notIn: others, progress: progress)
        XCTAssertGreaterThan(progress.fraction, 0)
    }

    // MARK: - ScanProgress primitive

    func testScanProgressFractionReachesOne() {
        let progress = ScanProgress(total: 10)
        XCTAssertEqual(progress.fraction, 0, accuracy: 0.0001)
        progress.add(5)
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 0.0001)
        progress.add(5)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)
    }

    func testScanProgressClampsAtOne() {
        let progress = ScanProgress(total: 4)
        progress.add(100)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)
    }

    func testScanProgressTreatsZeroTotalAsOne() {
        // total is clamped to at least 1 to avoid a divide-by-zero.
        let progress = ScanProgress(total: 0)
        XCTAssertEqual(progress.fraction, 0, accuracy: 0.0001)
        progress.add(1)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)
    }

    // MARK: - ScanCancellationToken primitive

    func testCancellationTokenStartsUncancelled() {
        XCTAssertFalse(ScanCancellationToken().isCancelled)
    }

    func testCancellationTokenReflectsCancel() {
        let token = ScanCancellationToken()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }
}
