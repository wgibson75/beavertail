//
//  LineVisibilityTests.swift
//  BeaverTailTests
//
//  Item 6: hide-above/below, minimap time-period selection, show-all and the
//  step-back history stack.
//

import XCTest
@testable import BeaverTail

@MainActor
final class LineVisibilityTests: XCTestCase {

    private var defaultsSnapshot: [String: Any?] = [:]
    private var viewModel: LogViewModel!
    private var tempURLs: [URL] = []
    private var tabID: UUID!

    override func setUp() {
        super.setUp()
        defaultsSnapshot = PersistedDefaults.clear()
        viewModel = LogViewModel()
        // A selected 100-line tab backed by in-memory content.
        let url = (try? writeTempFile("vis")) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("vis-\(UUID().uuidString).log")
        tempURLs.append(url)
        var tab = LogTab(name: "vis", fileURL: url,
                         content: LogContent.fromLines((0..<100).map { "line\($0)" }))
        tab.isCurrentlyStreaming = false
        tabID = tab.id
        viewModel.openTabs = [tab]
        viewModel.selectedTabID = tab.id
        viewModel.stopLiveTailing()
    }

    override func tearDown() {
        viewModel.stopLiveTailing()
        viewModel = nil
        for url in tempURLs { removeTempFile(url) }
        tempURLs = []
        PersistedDefaults.restore(defaultsSnapshot)
        super.tearDown()
    }

    private var tab: LogTab { viewModel.openTabs.first { $0.id == tabID }! }

    // MARK: - Hide above / below — Happy path

    func testHideLinesAboveSetsLowerBound() {
        viewModel.hideLinesAbove(originalIndex: 20)
        XCTAssertEqual(tab.visibleLowerBound, 20)
        XCTAssertNil(tab.visibleUpperBound)
        XCTAssertEqual(tab.visibleBoundsHistory.count, 1)
    }

    func testHideLinesBelowSetsUpperBound() {
        viewModel.hideLinesBelow(originalIndex: 80)
        XCTAssertEqual(tab.visibleUpperBound, 80)
        XCTAssertNil(tab.visibleLowerBound)
    }

    func testIsHidingLinesInCurrentTabReflectsState() {
        XCTAssertFalse(viewModel.isHidingLinesInCurrentTab)
        viewModel.hideLinesAbove(originalIndex: 10)
        XCTAssertTrue(viewModel.isHidingLinesInCurrentTab)
    }

    // MARK: - selectTimePeriod — Happy path & Boundaries

    func testSelectTimePeriodNarrowsToDraggedRange() {
        viewModel.selectTimePeriod(fromFraction: 0.2, toFraction: 0.6)
        XCTAssertEqual(tab.visibleLowerBound, 20)
        XCTAssertEqual(tab.visibleUpperBound, 60)
        XCTAssertEqual(tab.visibleBoundsHistory.count, 1)
    }

    func testSelectTimePeriodIsOrderIndependent() {
        viewModel.selectTimePeriod(fromFraction: 0.6, toFraction: 0.2)
        XCTAssertEqual(tab.visibleLowerBound, 20)
        XCTAssertEqual(tab.visibleUpperBound, 60)
    }

    // MARK: - Show all / step back — State transitions

    func testShowAllLinesClearsBoundsAndHistory() {
        viewModel.hideLinesAbove(originalIndex: 20)
        viewModel.showAllLines()
        XCTAssertNil(tab.visibleLowerBound)
        XCTAssertNil(tab.visibleUpperBound)
        XCTAssertTrue(tab.visibleBoundsHistory.isEmpty)
    }

    func testStepBackPopsPreviousRange() {
        viewModel.hideLinesAbove(originalIndex: 20) // history: [{nil,nil}]
        viewModel.hideLinesAbove(originalIndex: 40) // history: [{nil,nil},{20,nil}]
        XCTAssertEqual(tab.visibleLowerBound, 40)

        viewModel.stepBackTimePeriod() // restore {20,nil}
        XCTAssertEqual(tab.visibleLowerBound, 20)

        viewModel.stepBackTimePeriod() // restore {nil,nil} → fully revealed
        XCTAssertNil(tab.visibleLowerBound)
        XCTAssertNil(tab.visibleUpperBound)
    }

    // MARK: - step back — Failure modes / fallbacks

    func testStepBackWithNoHistoryButHidingFallsBackToShowAll() {
        // Hide directly without recording history, then step back.
        if let idx = viewModel.openTabs.firstIndex(where: { $0.id == tabID }) {
            viewModel.openTabs[idx].visibleLowerBound = 30
        }
        viewModel.stepBackTimePeriod()
        XCTAssertFalse(viewModel.isHidingLinesInCurrentTab)
    }

    func testStepBackWithNoHistoryAndNotHidingIsNoOp() {
        viewModel.stepBackTimePeriod() // must not crash
        XCTAssertNil(tab.visibleLowerBound)
        XCTAssertNil(tab.visibleUpperBound)
    }
}
