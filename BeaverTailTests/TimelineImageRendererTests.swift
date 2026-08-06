//
//  TimelineImageRendererTests.swift
//  BeaverTailTests
//
//  Item 4: the pure bucketing / priority-claiming algorithm behind the Timeline.
//

import XCTest
import AppKit
@testable import BeaverTail

@MainActor
final class TimelineImageRendererTests: XCTestCase {

    private func color(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private func makeInput(
        ruleColors: [CGColor],
        activeRuleIDs: [UUID],
        cache: [[Int]],
        isFiltered: Bool = false,
        filteredIndices: [Int] = [],
        sortedMarks: [Int] = [],
        hasMarks: Bool = false,
        rangeStart: Int = 0,
        rangeEnd: Int
    ) -> TimelineRenderInput {
        TimelineRenderInput(
            ruleColors: ruleColors,
            activeRuleIDs: activeRuleIDs,
            mappedCacheIndices: Array(0..<ruleColors.count),
            cache: cache,
            isFiltered: isFiltered,
            filteredIndices: filteredIndices,
            sortedMarks: sortedMarks,
            hasMarks: hasMarks,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            isDark: false
        )
    }

    // MARK: - Happy path

    func testUnfilteredColumnsAndPriorityClaiming() {
        // rule0 matches 2,10,50; rule1 matches 10,20. Line 10 is claimed by the
        // higher-priority rule0, so rule1 only "owns" line 20.
        let id0 = UUID(), id1 = UUID()
        let input = makeInput(
            ruleColors: [color(1, 0, 0), color(0, 0, 1)],
            activeRuleIDs: [id0, id1],
            cache: [[2, 10, 50], [10, 20]],
            rangeEnd: 100
        )
        let result = TimelineImageRenderer.render(input)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.matches, [[2, 10, 50], [20]])
        XCTAssertEqual(result?.activeRuleIDs, [id0, id1])
    }

    func testMarksColumnComesFirst() {
        let id0 = UUID()
        let input = makeInput(
            ruleColors: [color(1, 0, 0)],
            activeRuleIDs: [id0],
            cache: [[2]],
            sortedMarks: [5, 15],
            hasMarks: true,
            rangeEnd: 100
        )
        let result = TimelineImageRenderer.render(input)
        // Marks column first, then the rule column.
        XCTAssertEqual(result?.matches, [[5, 15], [2]])
        // activeRuleIDs reports only the rules that produced a column (not marks).
        XCTAssertEqual(result?.activeRuleIDs, [id0])
    }

    // MARK: - Edge cases & Boundaries

    func testZeroMatchesAndNoMarksReturnsNil() {
        let input = makeInput(
            ruleColors: [color(1, 0, 0)],
            activeRuleIDs: [UUID()],
            cache: [[]],
            rangeEnd: 100
        )
        XCTAssertNil(TimelineImageRenderer.render(input))
    }

    func testSingleLineLog() {
        let id0 = UUID()
        let input = makeInput(
            ruleColors: [color(0, 1, 0)],
            activeRuleIDs: [id0],
            cache: [[0]],
            rangeEnd: 1
        )
        let result = TimelineImageRenderer.render(input)
        XCTAssertEqual(result?.matches, [[0]])
        XCTAssertEqual(result?.activeRuleIDs, [id0])
    }

    func testFilteredPathOnlyCountsVisibleMatches() {
        // Only filtered lines 10,20,30 are visible. rule0 matches 10,25,30 — 25 is
        // not in the filtered set, so only 10 and 30 are represented.
        let id0 = UUID()
        let input = makeInput(
            ruleColors: [color(1, 0, 0)],
            activeRuleIDs: [id0],
            cache: [[10, 25, 30]],
            isFiltered: true,
            filteredIndices: [10, 20, 30],
            rangeEnd: 40
        )
        let result = TimelineImageRenderer.render(input)
        XCTAssertEqual(result?.matches, [[10, 30]])
        XCTAssertEqual(result?.activeRuleIDs, [id0])
    }

    func testRuleWithNoMatchesProducesNoColumn() {
        // rule0 matches; rule1 doesn't → only rule0 gets a column.
        let id0 = UUID(), id1 = UUID()
        let input = makeInput(
            ruleColors: [color(1, 0, 0), color(0, 0, 1)],
            activeRuleIDs: [id0, id1],
            cache: [[3], []],
            rangeEnd: 100
        )
        let result = TimelineImageRenderer.render(input)
        XCTAssertEqual(result?.matches, [[3]])
        XCTAssertEqual(result?.activeRuleIDs, [id0])
    }

    // MARK: - State / determinism

    func testDeterministicForIdenticalInput() {
        let id0 = UUID(), id1 = UUID()
        let make = {
            self.makeInput(
                ruleColors: [self.color(1, 0, 0), self.color(0, 0, 1)],
                activeRuleIDs: [id0, id1],
                cache: [[2, 10, 50], [20, 60]],
                rangeEnd: 200
            )
        }
        let first = TimelineImageRenderer.render(make())
        let second = TimelineImageRenderer.render(make())
        XCTAssertEqual(first?.matches, second?.matches)
        XCTAssertEqual(first?.activeRuleIDs, second?.activeRuleIDs)
    }

    // MARK: - Failure mode / cancellation

    func testCancelledTaskReturnsNil() async {
        let input = makeInput(
            ruleColors: [color(1, 0, 0)],
            activeRuleIDs: [UUID()],
            cache: [[1, 2, 3]],
            rangeEnd: 100
        )
        // Run render inside a task that is cancelled before it executes, so the
        // renderer observes `Task.isCancelled == true` and bails out with nil.
        let task = Task { () -> TimelineRenderResult? in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return TimelineImageRenderer.render(input)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }
}
