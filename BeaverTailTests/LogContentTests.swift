//
//  LogContentTests.swift
//  BeaverTailTests
//
//  Item 2b: LogContent line decoding, indexing (via mmap) and parallel filtering.
//

import XCTest
@testable import BeaverTail

@MainActor
final class LogContentTests: XCTestCase {

    // MARK: - fromLines / line(at:) — Happy path

    func testFromLinesRoundTrip() {
        let content = LogContent.fromLines(["one", "two", "three"])
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content.line(at: 0), "one")
        XCTAssertEqual(content.line(at: 1), "two")
        XCTAssertEqual(content.line(at: 2), "three")
    }

    // MARK: - line(at:) — Edge cases & Boundaries

    func testLineAtOutOfRangeReturnsEmpty() {
        let content = LogContent.fromLines(["only"])
        XCTAssertEqual(content.line(at: -1), "")
        XCTAssertEqual(content.line(at: 5), "")
    }

    func testFromLinesEmptyArray() {
        let content = LogContent.fromLines([])
        XCTAssertEqual(content.count, 0)
    }

    // MARK: - buildIndex via memory-mapped file — Happy path & Boundaries

    func testBuildIndexWithoutTrailingNewline() throws {
        let url = try writeTempFile("a\nbb\nccc")
        defer { removeTempFile(url) }
        let content = try LogContent.build(from: url)
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content.line(at: 0), "a")
        XCTAssertEqual(content.line(at: 1), "bb")
        XCTAssertEqual(content.line(at: 2), "ccc")
    }

    func testTrailingNewlineDoesNotProducePhantomLine() throws {
        let url = try writeTempFile("x\ny\n")
        defer { removeTempFile(url) }
        let content = try LogContent.build(from: url)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content.line(at: 0), "x")
        XCTAssertEqual(content.line(at: 1), "y")
    }

    func testCRLFLineEndingsAreStripped() throws {
        let url = try writeTempFile("p\r\nq\r\n")
        defer { removeTempFile(url) }
        let content = try LogContent.build(from: url)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content.line(at: 0), "p")
        XCTAssertEqual(content.line(at: 1), "q")
    }

    func testEmptyFileHasZeroLines() throws {
        let url = try writeTempFile("")
        defer { removeTempFile(url) }
        let content = try LogContent.build(from: url)
        XCTAssertEqual(content.count, 0)
    }

    // MARK: - filterMatches — Happy path (each matcher kind)

    func testFilterMatchesLiteralSensitive() {
        let content = LogContent.fromLines(["two", "one", "two"])
        let matcher = LineMatcher.make(pattern: "two", caseInsensitive: false)!
        let collector = MatchCollector()
        content.filterMatches(matcher: matcher, progress: ScanProgress(total: content.count)) {
            collector.record($0)
        }
        XCTAssertEqual(collector.latest, [0, 2])
    }

    func testFilterMatchesLiteralInsensitive() {
        let content = LogContent.fromLines(["Two", "xxx", "tWo"])
        let matcher = LineMatcher.make(pattern: "TWO", caseInsensitive: true)!
        let collector = MatchCollector()
        content.filterMatches(matcher: matcher, progress: ScanProgress(total: content.count)) {
            collector.record($0)
        }
        XCTAssertEqual(collector.latest, [0, 2])
    }

    func testFilterMatchesMultiLiteral() {
        let content = LogContent.fromLines(["one", "zzz", "two", "one"])
        let matcher = LineMatcher.make(pattern: "one|two", caseInsensitive: false)!
        let collector = MatchCollector()
        content.filterMatches(matcher: matcher, progress: ScanProgress(total: content.count)) {
            collector.record($0)
        }
        XCTAssertEqual(collector.latest, [0, 2, 3])
    }

    func testFilterMatchesRegexOnly() {
        let content = LogContent.fromLines(["fail", "foil", "xxx", "fl"])
        let matcher = LineMatcher.make(pattern: "f.*l", caseInsensitive: false)!
        let collector = MatchCollector()
        content.filterMatches(matcher: matcher, progress: ScanProgress(total: content.count)) {
            collector.record($0)
        }
        XCTAssertEqual(collector.latest, [0, 1, 3])
    }

    func testFilterMatchesRegexWithPrefilterGatesNonMatches() {
        // "colou?r" derives the prefilter "colo"; the third line contains "colo"
        // but lacks the trailing 'r', so the regex must reject it.
        let content = LogContent.fromLines(["color", "colour", "xxcoloxx", "nope"])
        let matcher = LineMatcher.make(pattern: "colou?r", caseInsensitive: false)!
        let collector = MatchCollector()
        content.filterMatches(matcher: matcher, progress: ScanProgress(total: content.count)) {
            collector.record($0)
        }
        XCTAssertEqual(collector.latest, [0, 1])
    }

    // MARK: - filterMatches — Edge cases & Boundaries

    func testFilterMatchesNoMatchesEmitsEmpty() {
        let content = LogContent.fromLines(["aaa", "bbb"])
        let matcher = LineMatcher.make(pattern: "zzz", caseInsensitive: false)!
        let collector = MatchCollector()
        content.filterMatches(matcher: matcher, progress: ScanProgress(total: content.count)) {
            collector.record($0)
        }
        XCTAssertEqual(collector.latest, [])
    }

    // MARK: - filterMatches — Failure modes / cancellation

    func testFilterMatchesCancelledBeforeStartDoesNotEmit() {
        let content = LogContent.fromLines(["two", "two"])
        let matcher = LineMatcher.make(pattern: "two", caseInsensitive: false)!
        let token = ScanCancellationToken()
        token.cancel()
        let collector = MatchCollector()
        content.filterMatches(
            matcher: matcher, progress: ScanProgress(total: content.count), cancellation: token
        ) {
            collector.record($0)
        }
        XCTAssertEqual(collector.callCount, 0, "a pre-cancelled scan must not publish results")
    }

    // MARK: - filterMatches — State / Concurrency

    func testFilterMatchesLargeInputCrossesChunkBoundaries() {
        let count = 20_000
        var lines: [String] = []
        lines.reserveCapacity(count)
        for i in 0..<count {
            lines.append(i % 3 == 0 ? "zz" : "no")
        }
        let content = LogContent.fromLines(lines)
        let matcher = LineMatcher.make(pattern: "zz", caseInsensitive: false)!
        let collector = MatchCollector()
        content.filterMatches(matcher: matcher, progress: ScanProgress(total: content.count)) {
            collector.record($0)
        }
        let expected = (0..<count).filter { $0 % 3 == 0 }
        XCTAssertEqual(collector.latest, expected)
    }

    // MARK: - extractAllMatches — Happy path

    func testExtractAllMatchesReturnsPerMatcherResults() {
        let content = LogContent.fromLines(["one", "two", "one"])
        let matchers = [
            LineMatcher.make(pattern: "one", caseInsensitive: false)!,
            LineMatcher.make(pattern: "two", caseInsensitive: false)!
        ]
        let collector = MultiMatchCollector()
        content.extractAllMatches(matchers: matchers) { snapshot, _ in
            collector.record(snapshot)
        }
        XCTAssertEqual(collector.latest, [[0, 2], [1]])
    }
}
