//
//  LiveTailServiceTests.swift
//  BeaverTailTests
//
//  Roadmap item 1: the LiveTailService extraction. Covers the pure line decoder
//  (CRLF stripping, partial-line remainder carry-over, no-newline buffering) and
//  the LiveTailFileMonitor poll state machine — unchanged / appended / rotated or
//  truncated / deleted transitions — exercised against real temp files.
//

import XCTest
@testable import BeaverTail

final class LiveTailServiceTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs = []
        super.tearDown()
    }

    private func tempFile(_ contents: String = "") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("livetail-\(UUID().uuidString).log")
        tempURLs.append(url)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - extractCompleteLines — Happy path

    func testExtractsCompleteLinesLeavingNoRemainder() {
        let (lines, remainder) = LiveTailService.extractCompleteLines(
            appending: Data("one\ntwo\nthree\n".utf8), to: Data()
        )
        XCTAssertEqual(lines, ["one", "two", "three"])
        XCTAssertTrue(remainder.isEmpty)
    }

    // MARK: - extractCompleteLines — Edge cases & Boundaries

    func testHoldsBackTrailingPartialLineAsRemainder() {
        let (lines, remainder) = LiveTailService.extractCompleteLines(
            appending: Data("one\ntwo\npar".utf8), to: Data()
        )
        XCTAssertEqual(lines, ["one", "two"])
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "par")
    }

    func testCarriesRemainderIntoNextReadToCompleteTheLine() {
        // First read ends mid-line; the leftover must complete on the next read.
        let (lines1, remainder1) = LiveTailService.extractCompleteLines(
            appending: Data("hello wor".utf8), to: Data()
        )
        XCTAssertTrue(lines1.isEmpty)
        XCTAssertEqual(String(decoding: remainder1, as: UTF8.self), "hello wor")

        let (lines2, remainder2) = LiveTailService.extractCompleteLines(
            appending: Data("ld\nnext\n".utf8), to: remainder1
        )
        XCTAssertEqual(lines2, ["hello world", "next"])
        XCTAssertTrue(remainder2.isEmpty)
    }

    func testSplitsOnNewlineCharacterSet() {
        // Behaviour preserved verbatim from the original inline live-tail decoder:
        // splitting uses the `.newlines` *character set*, so a bare `\n` line ending
        // yields exactly the expected lines with no blank interleaving.
        let (lines, remainder) = LiveTailService.extractCompleteLines(
            appending: Data("one\ntwo\n".utf8), to: Data()
        )
        XCTAssertEqual(lines, ["one", "two"])
        XCTAssertTrue(remainder.isEmpty)
    }

    func testNoNewlineBuffersEverythingAsRemainder() {
        let (lines, remainder) = LiveTailService.extractCompleteLines(
            appending: Data("no newline yet".utf8), to: Data()
        )
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "no newline yet")
    }

    // MARK: - LiveTailFileMonitor — Happy path (growth)

    func testPollReportsNoChangeWhenFileUnchanged() {
        let url = tempFile("existing line\n")
        let monitor = LiveTailFileMonitor(fileURL: url, hasInitialContent: true)
        XCTAssertEqual(monitor.poll(), .noChange)
    }

    func testPollReportsAppendedLinesOnGrowth() throws {
        let url = tempFile("first\n")
        let monitor = LiveTailFileMonitor(fileURL: url, hasInitialContent: true)
        XCTAssertEqual(monitor.poll(), .noChange)

        try append("second\nthird\n", to: url)
        XCTAssertEqual(monitor.poll(), .appended(lines: ["second", "third"]))
        // Already consumed — nothing new next tick.
        XCTAssertEqual(monitor.poll(), .noChange)
    }

    func testPollHoldsPartialLineUntilItCompletes() throws {
        let url = tempFile("done\n")
        let monitor = LiveTailFileMonitor(fileURL: url, hasInitialContent: true)
        XCTAssertEqual(monitor.poll(), .noChange)

        // Append a line with no terminating newline yet — nothing to emit.
        try append("partial", to: url)
        XCTAssertEqual(monitor.poll(), .noChange)

        // Completing the line makes it available on the next poll.
        try append(" line\n", to: url)
        XCTAssertEqual(monitor.poll(), .appended(lines: ["partial line"]))
    }

    // MARK: - LiveTailFileMonitor — Rotation / truncation

    func testPollReportsResetWhenFileShrinks() throws {
        let url = tempFile("aaaa\nbbbb\ncccc\n")
        let monitor = LiveTailFileMonitor(fileURL: url, hasInitialContent: true)
        XCTAssertEqual(monitor.poll(), .noChange)

        // Truncate (simulating log rotation).
        try Data("x\n".utf8).write(to: url)
        XCTAssertEqual(monitor.poll(), .reset)
    }

    // MARK: - LiveTailFileMonitor — Deletion & recreation

    func testPollReportsFileDisappearedOnceThenNoChange() throws {
        let url = tempFile("line\n")
        let monitor = LiveTailFileMonitor(fileURL: url, hasInitialContent: true)
        XCTAssertEqual(monitor.poll(), .noChange)

        try FileManager.default.removeItem(at: url)
        // Reported exactly once...
        XCTAssertEqual(monitor.poll(), .fileDisappeared)
        // ...then stays quiet while it remains missing.
        XCTAssertEqual(monitor.poll(), .noChange)
    }

    func testPollReportsResetWhenFileReappearsAfterDeletion() throws {
        let url = tempFile("line\n")
        let monitor = LiveTailFileMonitor(fileURL: url, hasInitialContent: true)
        XCTAssertEqual(monitor.poll(), .noChange)

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(monitor.poll(), .fileDisappeared)

        // Recreated: the whole file must be re-read.
        FileManager.default.createFile(atPath: url.path, contents: Data("fresh\n".utf8))
        XCTAssertEqual(monitor.poll(), .reset)
    }

    func testMissingFileWithNoLoadedContentResetsWhenItAppears() throws {
        // A tab with no in-memory content whose backing file isn't there yet: the
        // monitor starts "absent", so the file appearing later triggers a reset (a
        // full read via the standard lazy load) rather than a partial append.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("livetail-missing-\(UUID().uuidString).log")
        tempURLs.append(url)

        let monitor = LiveTailFileMonitor(fileURL: url, hasInitialContent: false)
        FileManager.default.createFile(atPath: url.path, contents: Data("appeared\n".utf8))
        XCTAssertEqual(monitor.poll(), .reset)
    }
}
