//
//  FileLoadServiceTests.swift
//  BeaverTailTests
//
//  FileLoadService extraction: the publish-throttle decision (pure) and the
//  incremental map + index end-to-end against real temp files.
//

import XCTest
@testable import BeaverTail

final class FileLoadServiceTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs { removeTempFile(url) }
        tempURLs = []
        super.tearDown()
    }

    private func tempFile(_ contents: String) throws -> URL {
        let url = try writeTempFile(contents)
        tempURLs.append(url)
        return url
    }

    // MARK: - shouldPublishPartial — Happy path & Boundaries

    func testFirstPartialAlwaysPublishesRegardlessOfElapsed() {
        // The very first snapshot must fire immediately even with zero elapsed time.
        XCTAssertTrue(FileLoadService.shouldPublishPartial(didPublishFirst: false, elapsedMilliseconds: 0))
        XCTAssertTrue(FileLoadService.shouldPublishPartial(didPublishFirst: false, elapsedMilliseconds: 5))
    }

    func testSubsequentPartialThrottledUntilIntervalElapses() {
        let throttle = FileLoadService.publishThrottleMilliseconds
        // Inside the window: coalesced (skipped).
        XCTAssertFalse(FileLoadService.shouldPublishPartial(didPublishFirst: true, elapsedMilliseconds: 0))
        XCTAssertFalse(FileLoadService.shouldPublishPartial(didPublishFirst: true, elapsedMilliseconds: throttle - 1))
        // At/after the window: publishes.
        XCTAssertTrue(FileLoadService.shouldPublishPartial(didPublishFirst: true, elapsedMilliseconds: throttle))
        XCTAssertTrue(FileLoadService.shouldPublishPartial(didPublishFirst: true, elapsedMilliseconds: throttle + 500))
    }

    func testCustomThrottleIntervalHonoured() {
        XCTAssertFalse(FileLoadService.shouldPublishPartial(didPublishFirst: true, elapsedMilliseconds: 9, throttleMilliseconds: 10))
        XCTAssertTrue(FileLoadService.shouldPublishPartial(didPublishFirst: true, elapsedMilliseconds: 10, throttleMilliseconds: 10))
    }

    // MARK: - loadIncrementally — Happy path

    func testLoadIncrementallyReturnsFullyIndexedContent() throws {
        let url = try tempFile("alpha\nbravo\ncharlie\n")
        let progress = ScanProgress(total: 100)

        var partials = 0
        let content = try FileLoadService.loadIncrementally(
            from: url, progress: progress, onPartial: { _ in partials += 1 }
        )

        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content.line(at: 0), "alpha")
        XCTAssertEqual(content.line(at: 1), "bravo")
        XCTAssertEqual(content.line(at: 2), "charlie")
        // The first segment always publishes, so at least one partial is delivered.
        XCTAssertGreaterThanOrEqual(partials, 1)
    }

    func testLoadIncrementallyHandlesFileWithoutTrailingNewline() throws {
        let url = try tempFile("a\nbb\nccc")
        let content = try FileLoadService.loadIncrementally(
            from: url, progress: ScanProgress(total: 10), onPartial: { _ in }
        )
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content.line(at: 2), "ccc")
    }

    // MARK: - loadIncrementally — Edge cases & failure modes

    func testLoadIncrementallyEmptyFileHasZeroLines() throws {
        let url = try tempFile("")
        let content = try FileLoadService.loadIncrementally(
            from: url, progress: ScanProgress(total: 1), onPartial: { _ in }
        )
        XCTAssertEqual(content.count, 0)
    }

    func testLoadIncrementallyThrowsForMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).log")
        XCTAssertThrowsError(try FileLoadService.loadIncrementally(
            from: missing, progress: ScanProgress(total: 1), onPartial: { _ in }
        ))
    }

    func testSegmentScanHooksAreInvoked() throws {
        let url = try tempFile("one\ntwo\n")
        var willScan = 0
        var didScan = 0
        _ = try FileLoadService.loadIncrementally(
            from: url,
            progress: ScanProgress(total: 10),
            onSegmentWillScan: { willScan += 1; return true },
            onSegmentDidScan: { didScan += 1 },
            onPartial: { _ in }
        )
        // A non-empty file scans at least one segment, bracketed by the hooks.
        XCTAssertGreaterThanOrEqual(willScan, 1)
        XCTAssertEqual(willScan, didScan)
    }
}
