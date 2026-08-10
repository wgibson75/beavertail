//
//  MinimapImageRendererTests.swift
//  BeaverTailTests
//
//  MinimapImageRenderer extraction: the pure `minimapFills` bucketing core behind
//  the minimap highlight strip, plus a couple of `render` end-to-end assertions.
//

import XCTest
import AppKit
@testable import BeaverTail

@MainActor
final class MinimapImageRendererTests: XCTestCase {

    private func color(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private func makeInput(
        colors: [CGColor],
        cache: [[Int]],
        rangeStart: Int = 0,
        rangeEnd: Int,
        imageWidth: Int = 30,
        imageHeight: Int
    ) -> MinimapRenderInput {
        MinimapRenderInput(
            colors: colors,
            cache: cache,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
    }

    // MARK: - minimapFills — MANY-lines regime (rangeSpan >= imageHeight)

    func testManyLinesBucketsColouredByHighestPriorityRule() {
        // 100 lines into 10 pixel rows → 10 lines per bucket. rule0 (red) matches a
        // line in bucket 0; rule1 (blue) matches a line in bucket 5. Bucket 2 also
        // has a rule1 match. Each populated bucket is a 1px band.
        let input = makeInput(
            colors: [color(1, 0, 0), color(0, 0, 1)],
            cache: [[3], [25, 55]],
            rangeEnd: 100,
            imageHeight: 10
        )
        let fills = MinimapImageRenderer.minimapFills(for: input)

        // Buckets 0 (line 3, red), 2 (line 25, blue), 5 (line 55, blue).
        XCTAssertEqual(fills.map { $0.yTop }, [0, 2, 5])
        XCTAssertTrue(fills.allSatisfy { $0.height == 1 })
        XCTAssertEqual(fills[0].color, color(1, 0, 0))
        XCTAssertEqual(fills[1].color, color(0, 0, 1))
        XCTAssertEqual(fills[2].color, color(0, 0, 1))
    }

    func testManyLinesBucketPrefersEarlierRuleOnOverlap() {
        // Both rules match within the same bucket (0..<10). The highest-priority
        // (earliest) rule colours the band; alpha reflects the TOTAL match density.
        let input = makeInput(
            colors: [color(1, 0, 0), color(0, 0, 1)],
            cache: [[1], [2]],
            rangeEnd: 100,
            imageHeight: 10
        )
        let fills = MinimapImageRenderer.minimapFills(for: input)
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills[0].yTop, 0)
        XCTAssertEqual(fills[0].color, color(1, 0, 0))
        // 2 matches across 10 lines → density 0.2 → alpha max(0.45, 0.2*5)=1.0.
        XCTAssertEqual(fills[0].alpha, 1.0, accuracy: 0.0001)
    }

    func testManyLinesAlphaFloorForSparseBucket() {
        // 1000 lines into 10 rows → 100 lines/bucket. One match → density 0.01 →
        // 0.01*5 = 0.05, clamped up to the 0.45 floor.
        let input = makeInput(
            colors: [color(1, 0, 0)],
            cache: [[50]],
            rangeEnd: 1000,
            imageHeight: 10
        )
        let fills = MinimapImageRenderer.minimapFills(for: input)
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills[0].alpha, 0.45, accuracy: 0.0001)
    }

    // MARK: - minimapFills — FEW-lines regime (rangeSpan < imageHeight)

    func testFewLinesFillFullBandsLowPriorityFirst() {
        // 2 visible lines into 10 rows → each line spans 5 rows. Draw order is
        // low-priority (rule1) first so the highest-priority rule wins on overlap.
        let input = makeInput(
            colors: [color(1, 0, 0), color(0, 0, 1)],
            cache: [[0], [1]],
            rangeEnd: 2,
            imageHeight: 10
        )
        let fills = MinimapImageRenderer.minimapFills(for: input)
        XCTAssertEqual(fills.count, 2)
        // rule1 (blue) emitted first: line 1 → rows [5, 10).
        XCTAssertEqual(fills[0].color, color(0, 0, 1))
        XCTAssertEqual(fills[0].yTop, 5)
        XCTAssertEqual(fills[0].height, 5)
        XCTAssertEqual(fills[0].alpha, 1.0, accuracy: 0.0001)
        // rule0 (red) emitted second: line 0 → rows [0, 5).
        XCTAssertEqual(fills[1].color, color(1, 0, 0))
        XCTAssertEqual(fills[1].yTop, 0)
        XCTAssertEqual(fills[1].height, 5)
    }

    func testFewLinesRestrictedToVisibleRange() {
        // Only lines 10..<12 are visible; matches outside the range are ignored and
        // positions are relative to rangeStart.
        let input = makeInput(
            colors: [color(1, 0, 0)],
            cache: [[5, 10, 11, 20]],
            rangeStart: 10,
            rangeEnd: 12,
            imageHeight: 10
        )
        let fills = MinimapImageRenderer.minimapFills(for: input)
        // rel 0 → [0,5), rel 1 → [5,10).
        XCTAssertEqual(fills.map { $0.yTop }, [0, 5])
        XCTAssertTrue(fills.allSatisfy { $0.height == 5 })
    }

    // MARK: - minimapFills — Edge cases

    func testEmptyRangeProducesNoFills() {
        let input = makeInput(colors: [color(1, 0, 0)], cache: [[0]], rangeStart: 5, rangeEnd: 5, imageHeight: 10)
        XCTAssertTrue(MinimapImageRenderer.minimapFills(for: input).isEmpty)
    }

    func testNoMatchesProducesNoFills() {
        let input = makeInput(colors: [color(1, 0, 0)], cache: [[]], rangeEnd: 100, imageHeight: 10)
        XCTAssertTrue(MinimapImageRenderer.minimapFills(for: input).isEmpty)
    }

    func testCancellationStopsFillGeneration() {
        let input = makeInput(colors: [color(1, 0, 0)], cache: [[3, 25, 55]], rangeEnd: 100, imageHeight: 10)
        let fills = MinimapImageRenderer.minimapFills(for: input, isCancelled: { true })
        XCTAssertTrue(fills.isEmpty)
    }

    // MARK: - render — end to end

    func testRenderProducesImageForValidInput() {
        let input = makeInput(colors: [color(1, 0, 0)], cache: [[3, 25, 55]], rangeEnd: 100, imageHeight: 100)
        let image = MinimapImageRenderer.render(input)
        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size, NSSize(width: 30, height: 100))
    }

    func testRenderReturnsNilForEmptyRange() {
        let input = makeInput(colors: [color(1, 0, 0)], cache: [[3]], rangeStart: 7, rangeEnd: 7, imageHeight: 100)
        XCTAssertNil(MinimapImageRenderer.render(input))
    }

    func testRenderReturnsBlankImageWhenNothingMatches() {
        // A valid range with no matches still yields a (transparent) image, matching
        // the previous inline behaviour (the view shows an empty strip, not nil).
        let input = makeInput(colors: [color(1, 0, 0)], cache: [[]], rangeEnd: 100, imageHeight: 100)
        XCTAssertNotNil(MinimapImageRenderer.render(input))
    }
}
