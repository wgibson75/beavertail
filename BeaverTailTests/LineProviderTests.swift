//
//  LineProviderTests.swift
//  BeaverTailTests
//
//  Item 3a: FilteredLineProvider / RangeLineProvider index maths.
//

import XCTest
@testable import BeaverTail

@MainActor
final class LineProviderTests: XCTestCase {

    // MARK: - firstOffset(in:where:) — Happy path & Boundaries

    func testFirstOffsetLowerBound() {
        let arr = [10, 20, 30, 40]
        XCTAssertEqual(FilteredLineProvider.firstOffset(in: arr) { $0 >= 25 }, 2)
    }

    func testFirstOffsetAllMatch() {
        let arr = [10, 20, 30, 40]
        XCTAssertEqual(FilteredLineProvider.firstOffset(in: arr) { $0 >= 10 }, 0)
    }

    func testFirstOffsetNoneMatch() {
        let arr = [10, 20, 30, 40]
        XCTAssertEqual(FilteredLineProvider.firstOffset(in: arr) { $0 >= 100 }, 4)
    }

    func testFirstOffsetEmptyArray() {
        XCTAssertEqual(FilteredLineProvider.firstOffset(in: []) { $0 >= 0 }, 0)
    }

    // MARK: - countInRange — Happy path & Boundaries

    func testCountInRangeInterior() {
        XCTAssertEqual(FilteredLineProvider.countInRange([10, 20, 30, 40], lower: 15, upper: 35), 2)
    }

    func testCountInRangeFullSpan() {
        XCTAssertEqual(FilteredLineProvider.countInRange([10, 20, 30, 40], lower: 10, upper: 40), 4)
    }

    func testCountInRangeAboveAll() {
        XCTAssertEqual(FilteredLineProvider.countInRange([10, 20, 30, 40], lower: 41, upper: 50), 0)
    }

    func testCountInRangeBelowAll() {
        XCTAssertEqual(FilteredLineProvider.countInRange([10, 20, 30, 40], lower: 0, upper: 5), 0)
    }

    // MARK: - FilteredLineProvider — Happy path (no bounds)

    func testFilteredProviderExposesMatchedLines() {
        let content = LogContent.fromLines(["L0", "L1", "L2", "L3", "L4"])
        let provider = FilteredLineProvider(content: content, indices: [1, 3])
        XCTAssertEqual(provider.count, 2)
        XCTAssertEqual(provider.line(at: 0), "L1")
        XCTAssertEqual(provider.line(at: 1), "L3")
        XCTAssertEqual(provider.originalIndex(at: 0), 1)
        XCTAssertEqual(provider.originalIndex(at: 1), 3)
    }

    // MARK: - FilteredLineProvider — Edge cases (visible bounds)

    func testFilteredProviderRestrictsToVisibleRange() {
        let content = LogContent.fromLines(["L0", "L1", "L2", "L3", "L4"])
        let provider = FilteredLineProvider(
            content: content, indices: [0, 1, 2, 3, 4],
            visibleLowerBound: 1, visibleUpperBound: 3
        )
        XCTAssertEqual(provider.count, 3)
        XCTAssertEqual(provider.line(at: 0), "L1")
        XCTAssertEqual(provider.originalIndex(at: 0), 1)
        XCTAssertEqual(provider.originalIndex(at: 2), 3)
    }

    func testFilteredProviderOutOfRangeReturnsEmpty() {
        let content = LogContent.fromLines(["L0", "L1"])
        let provider = FilteredLineProvider(content: content, indices: [0, 1])
        XCTAssertEqual(provider.line(at: -1), "")
        XCTAssertEqual(provider.line(at: 5), "")
    }

    // MARK: - RangeLineProvider — Happy path & Boundaries

    func testRangeProviderExposesContiguousSubrange() {
        let content = LogContent.fromLines(["r0", "r1", "r2", "r3"])
        let provider = RangeLineProvider(content: content, lowerBound: 1, rangeCount: 2)
        XCTAssertEqual(provider.count, 2)
        XCTAssertEqual(provider.line(at: 0), "r1")
        XCTAssertEqual(provider.line(at: 1), "r2")
        XCTAssertEqual(provider.originalIndex(at: 0), 1)
        XCTAssertEqual(provider.originalIndex(at: 1), 2)
    }

    func testRangeProviderOutOfRange() {
        let content = LogContent.fromLines(["r0", "r1", "r2", "r3"])
        let provider = RangeLineProvider(content: content, lowerBound: 1, rangeCount: 2)
        XCTAssertEqual(provider.line(at: 5), "")
        // originalIndex falls back to the passed index when out of range.
        XCTAssertEqual(provider.originalIndex(at: 5), 5)
    }
}
