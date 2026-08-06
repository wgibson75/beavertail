//
//  FileExportServiceTests.swift
//  BeaverTailTests
//
//  Item 11: export filename generation and buffered line writing.
//

import XCTest
@testable import BeaverTail

/// A synthetic provider returning a fixed line, used to exercise the >1 MB buffer
/// flush without materialising a huge array.
private struct RepeatingLineProvider: LineProvider, @unchecked Sendable {
    let count: Int
    let text: String
    nonisolated func line(at index: Int) -> String { text }
}

final class FileExportServiceTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        for url in tempURLs { removeTempFile(url) }
        tempURLs = []
        super.tearDown()
    }

    private func tempDestination() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).txt")
        tempURLs.append(url)
        return url
    }

    // MARK: - suggestedFilteredExportName — Happy path & Boundaries

    func testSuggestedNameStripsExtension() {
        XCTAssertEqual(FileExportService.suggestedFilteredExportName(forTabNamed: "server.log"),
                       "server-filtered.txt")
    }

    func testSuggestedNameForEmptyDefaultsToLog() {
        XCTAssertEqual(FileExportService.suggestedFilteredExportName(forTabNamed: ""),
                       "log-filtered.txt")
    }

    func testSuggestedNameStripsOnlyLastExtension() {
        XCTAssertEqual(FileExportService.suggestedFilteredExportName(forTabNamed: "a.b.c"),
                       "a.b-filtered.txt")
    }

    // MARK: - writeLines — Happy path

    func testWritesNewlineSeparatedLines() throws {
        let url = tempDestination()
        let provider = ArrayLineProvider(lines: ["one", "two", "three"])
        FileExportService.writeLines(from: provider, count: 3, to: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents, "one\ntwo\nthree\n")
    }

    // MARK: - writeLines — Edge cases & Boundaries

    func testWritesEmptyFileForZeroCount() throws {
        let url = tempDestination()
        FileExportService.writeLines(from: ArrayLineProvider(lines: []), count: 0, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 0)
    }

    func testFlushesWhenExceedingBufferThreshold() throws {
        let url = tempDestination()
        // 150k lines of 20 chars (+newline) ≈ 3 MB, well past the ~1 MB flush point.
        let count = 150_000
        let provider = RepeatingLineProvider(count: count, text: String(repeating: "x", count: 20))
        FileExportService.writeLines(from: provider, count: count, to: url)

        let data = try Data(contentsOf: url)
        // One newline per line.
        let newlineCount = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        XCTAssertEqual(newlineCount, count)
        XCTAssertGreaterThan(data.count, 1 << 20)
    }
}
