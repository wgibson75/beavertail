//
//  SessionStoreTests.swift
//  BeaverTailTests
//
//  Item 10: session JSON codec and file-bookmark round trips.
//

import XCTest
@testable import BeaverTail

final class SessionStoreTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs { removeTempFile(url) }
        tempURLs = []
        super.tearDown()
    }

    private func makeTempFile() -> URL {
        let url = (try? writeTempFile("session log")) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).log")
        tempURLs.append(url)
        return url
    }

    // MARK: - JSON codec — Happy path

    func testEncodeDecodeRoundTrip() {
        let metadata = [
            SavedTabMetadata(
                bookmarkBase64: "abc123", filterPattern: "err",
                isSelected: true, markedIndices: [1, 2, 3],
                isCaseInsensitive: false, followTail: true
            )
        ]
        guard let encoded = SessionStore.encode(metadata) else {
            return XCTFail("encode returned nil")
        }
        let decoded = SessionStore.decode(from: encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.bookmarkBase64, "abc123")
        XCTAssertEqual(decoded.first?.filterPattern, "err")
        XCTAssertEqual(decoded.first?.isSelected, true)
        XCTAssertEqual(decoded.first?.markedIndices, [1, 2, 3])
        XCTAssertEqual(decoded.first?.isCaseInsensitive, false)
        XCTAssertEqual(decoded.first?.followTail, true)
    }

    // MARK: - JSON codec — Edge cases & Boundaries

    func testDecodeEmptyStringReturnsEmpty() {
        XCTAssertTrue(SessionStore.decode(from: "").isEmpty)
    }

    func testDecodeMalformedStringReturnsEmpty() {
        XCTAssertTrue(SessionStore.decode(from: "not-json").isEmpty)
    }

    func testEncodeEmptyMetadata() {
        let encoded = SessionStore.encode([])
        XCTAssertNotNil(encoded)
        XCTAssertTrue(SessionStore.decode(from: encoded ?? "x").isEmpty)
    }

    // MARK: - Bookmarks — Happy path

    func testBookmarkRoundTripResolvesToSameFile() throws {
        let url = makeTempFile()
        let base64 = try SessionStore.makeBookmark(for: url)
        let resolved = SessionStore.resolveBookmark(base64)
        XCTAssertEqual(resolved?.standardizedFileURL, url.standardizedFileURL)
    }

    // MARK: - Bookmarks — Failure modes

    func testResolveMalformedBase64ReturnsNil() {
        XCTAssertNil(SessionStore.resolveBookmark("!!!not-base64!!!"))
    }

    func testResolveBookmarkForDeletedFileReturnsNil() throws {
        let url = makeTempFile()
        let base64 = try SessionStore.makeBookmark(for: url)
        removeTempFile(url)
        XCTAssertNil(SessionStore.resolveBookmark(base64))
    }
}
