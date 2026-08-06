//
//  LogTabTests.swift
//  BeaverTailTests
//
//  Item 3b: LogTab visible-bounds maths, codable round-trip and equality.
//

import XCTest
@testable import BeaverTail

@MainActor
final class LogTabTests: XCTestCase {

    private func makeTab(
        id: UUID = UUID(),
        content: LogContent? = nil,
        filterPattern: String = "",
        markedIndices: Set<Int> = [],
        mark: LogMark? = nil
    ) -> LogTab {
        var tab = LogTab(
            id: id,
            name: "tab",
            fileURL: URL(fileURLWithPath: "/tmp/example.log"),
            content: content,
            markedIndices: markedIndices,
            filterPattern: filterPattern
        )
        tab.mark = mark
        return tab
    }

    // MARK: - visibleBounds(for:) — Happy path

    func testVisibleBoundsNilWhenNotHiding() {
        let tab = makeTab()
        XCTAssertNil(tab.visibleBounds(for: 10))
    }

    func testVisibleBoundsClampsToTotal() {
        var tab = makeTab()
        tab.visibleLowerBound = 2
        // Open-ended upper resolves to total - 1.
        XCTAssertEqual(tab.visibleBounds(for: 10)?.lower, 2)
        XCTAssertEqual(tab.visibleBounds(for: 10)?.upper, 9)
    }

    func testVisibleBoundsExplicitRange() {
        var tab = makeTab()
        tab.visibleLowerBound = 2
        tab.visibleUpperBound = 5
        let bounds = tab.visibleBounds(for: 10)
        XCTAssertEqual(bounds?.lower, 2)
        XCTAssertEqual(bounds?.upper, 5)
    }

    // MARK: - visibleBounds(for:) — Edge cases & Boundaries

    func testVisibleBoundsNilWhenLowerExceedsUpper() {
        var tab = makeTab()
        tab.visibleLowerBound = 8
        tab.visibleUpperBound = 3
        XCTAssertNil(tab.visibleBounds(for: 10))
    }

    func testVisibleBoundsNilForEmptyLog() {
        var tab = makeTab()
        tab.visibleLowerBound = 0
        XCTAssertNil(tab.visibleBounds(for: 0))
    }

    func testIsHidingLinesReflectsBounds() {
        var tab = makeTab()
        XCTAssertFalse(tab.isHidingLines)
        tab.visibleUpperBound = 4
        XCTAssertTrue(tab.isHidingLines)
    }

    // MARK: - line counts — Happy path & Boundaries

    func testLineCountFullWhenNotHiding() {
        let content = LogContent.fromLines((0..<10).map { "line\($0)" })
        let tab = makeTab(content: content)
        XCTAssertEqual(tab.lineCount, 10)
    }

    func testLineCountReflectsVisibleRange() {
        let content = LogContent.fromLines((0..<10).map { "line\($0)" })
        var tab = makeTab(content: content)
        tab.visibleLowerBound = 2
        tab.visibleUpperBound = 5
        XCTAssertEqual(tab.lineCount, 4)
    }

    func testTotalLineCountIgnoresHiding() {
        let content = LogContent.fromLines((0..<10).map { "line\($0)" })
        var tab = makeTab(content: content)
        tab.visibleLowerBound = 2
        tab.visibleUpperBound = 5
        XCTAssertEqual(tab.totalLineCount, 10)
    }

    func testHiddenLineCounts() {
        let content = LogContent.fromLines((0..<10).map { "line\($0)" })
        var tab = makeTab(content: content)
        tab.visibleLowerBound = 2
        tab.visibleUpperBound = 5
        let hidden = tab.hiddenLineCounts
        XCTAssertEqual(hidden?.above, 2)
        XCTAssertEqual(hidden?.below, 4)
    }

    func testHiddenLineCountsNilWhenNotHiding() {
        let content = LogContent.fromLines((0..<10).map { "line\($0)" })
        let tab = makeTab(content: content)
        XCTAssertNil(tab.hiddenLineCounts)
    }

    // MARK: - filteredCount — Happy path, Boundaries & filter message

    func testFilteredCountFullWhenNotHiding() {
        let content = LogContent.fromLines((0..<10).map { "line\($0)" })
        var tab = makeTab(content: content)
        tab.displayedIndices = [0, 2, 4, 6, 8]
        XCTAssertEqual(tab.filteredCount, 5)
    }

    func testFilteredCountClampsToVisibleRange() {
        let content = LogContent.fromLines((0..<10).map { "line\($0)" })
        var tab = makeTab(content: content)
        tab.displayedIndices = [0, 2, 4, 6, 8]
        tab.visibleLowerBound = 2
        tab.visibleUpperBound = 6
        // Only indices 2, 4, 6 fall inside the visible range.
        XCTAssertEqual(tab.filteredCount, 3)
    }

    func testFilteredCountIsOneWhenShowingFilterMessage() {
        var tab = makeTab()
        tab.filterMessage = "Invalid regular expression"
        XCTAssertEqual(tab.filteredCount, 1)
    }

    // MARK: - Codable — Happy path

    func testCodableRoundTrip() throws {
        let id = UUID()
        var tab = makeTab(id: id, filterPattern: "needle", markedIndices: [3, 1, 2])
        tab.isCaseInsensitive = false
        tab.followTail = false

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(LogTab.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "tab")
        XCTAssertEqual(decoded.fileURL, URL(fileURLWithPath: "/tmp/example.log"))
        XCTAssertEqual(decoded.filterPattern, "needle")
        XCTAssertEqual(decoded.markedIndices, [1, 2, 3])
        XCTAssertFalse(decoded.isCaseInsensitive)
        XCTAssertFalse(decoded.followTail)
        // Decoding derives displayedIndices from the sorted marked set.
        XCTAssertEqual(decoded.displayedIndices, [1, 2, 3])
    }

    // MARK: - Equality — Happy path & discrimination

    func testEqualTabsCompareEqual() {
        let id = UUID()
        let lhs = makeTab(id: id, filterPattern: "p", markedIndices: [1, 2])
        let rhs = makeTab(id: id, filterPattern: "p", markedIndices: [1, 2])
        XCTAssertEqual(lhs, rhs)
    }

    func testTabsDifferingByMarkAreNotEqual() {
        let id = UUID()
        let lhs = makeTab(id: id, filterPattern: "p", markedIndices: [1, 2], mark: .good)
        let rhs = makeTab(id: id, filterPattern: "p", markedIndices: [1, 2], mark: .bad)
        XCTAssertNotEqual(lhs, rhs)
    }
}
