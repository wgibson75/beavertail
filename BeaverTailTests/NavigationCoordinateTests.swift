//
//  NavigationCoordinateTests.swift
//  BeaverTailTests
//
//  Item 5: hidden-line-aware coordinate mapping and timeline-heading match jumps.
//

import XCTest
@testable import BeaverTail

@MainActor
final class NavigationCoordinateTests: XCTestCase {

    private var defaultsSnapshot: [String: Any?] = [:]
    private var viewModel: LogViewModel!
    private var tempURLs: [URL] = []

    override func setUp() {
        super.setUp()
        defaultsSnapshot = PersistedDefaults.clear()
        viewModel = LogViewModel()
    }

    override func tearDown() {
        viewModel.stopLiveTailing()
        viewModel = nil
        for url in tempURLs { removeTempFile(url) }
        tempURLs = []
        PersistedDefaults.restore(defaultsSnapshot)
        super.tearDown()
    }

    private func makeTab(lineCount: Int) -> LogTab {
        let url = (try? writeTempFile("nav")) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("nav-\(UUID().uuidString).log")
        tempURLs.append(url)
        let lines = (0..<lineCount).map { "line\($0)" }
        return LogTab(name: "nav", fileURL: url, content: LogContent.fromLines(lines))
    }

    // MARK: - minimapFraction / originalIndex — Happy path

    func testMinimapFractionEndpoints() {
        let tab = makeTab(lineCount: 100)
        XCTAssertEqual(viewModel.minimapFraction(forOriginalIndex: 0, in: tab), 0, accuracy: 0.0001)
        XCTAssertEqual(viewModel.minimapFraction(forOriginalIndex: 99, in: tab), 1, accuracy: 0.0001)
    }

    func testOriginalIndexEndpoints() {
        let tab = makeTab(lineCount: 100)
        XCTAssertEqual(viewModel.originalIndex(forFraction: 0, in: tab), 0)
        XCTAssertEqual(viewModel.originalIndex(forFraction: 1, in: tab), 99)
        XCTAssertEqual(viewModel.originalIndex(forFraction: 0.5, in: tab), 50)
    }

    func testFractionIndexRoundTrip() {
        let tab = makeTab(lineCount: 100)
        for line in [0, 1, 25, 50, 75, 99] {
            let fraction = viewModel.minimapFraction(forOriginalIndex: line, in: tab)
            XCTAssertEqual(viewModel.originalIndex(forFraction: fraction, in: tab), line)
        }
    }

    // MARK: - Edge cases & Boundaries

    func testSingleLineHasNoDivideByZero() {
        let tab = makeTab(lineCount: 1)
        XCTAssertEqual(viewModel.minimapFraction(forOriginalIndex: 0, in: tab), 0, accuracy: 0.0001)
        XCTAssertEqual(viewModel.originalIndex(forFraction: 0.5, in: tab), 0)
    }

    func testFractionsAreClamped() {
        let tab = makeTab(lineCount: 100)
        XCTAssertEqual(viewModel.originalIndex(forFraction: 2.0, in: tab), 99)
        XCTAssertEqual(viewModel.originalIndex(forFraction: -1.0, in: tab), 0)
        XCTAssertEqual(viewModel.minimapFraction(forOriginalIndex: 500, in: tab), 1, accuracy: 0.0001)
    }

    func testSelectedOriginalIndexUsesStoredFraction() {
        let tab = makeTab(lineCount: 100)
        viewModel.selectedFractionByTab[tab.id] = 0.5
        XCTAssertEqual(viewModel.selectedOriginalIndex(in: tab), 50)
    }

    func testSelectedOriginalIndexNilWhenNoSelection() {
        let tab = makeTab(lineCount: 100)
        XCTAssertNil(viewModel.selectedOriginalIndex(in: tab))
    }

    func testCoordinateMappingRespectsHiddenRange() {
        var tab = makeTab(lineCount: 100)
        tab.visibleLowerBound = 10
        tab.visibleUpperBound = 59 // 50 visible lines
        XCTAssertEqual(viewModel.minimapFraction(forOriginalIndex: 10, in: tab), 0, accuracy: 0.0001)
        XCTAssertEqual(viewModel.minimapFraction(forOriginalIndex: 59, in: tab), 1, accuracy: 0.0001)
        // Fraction 0.5 across 50 visible lines lands at offset 25 → original line 35.
        XCTAssertEqual(viewModel.originalIndex(forFraction: 0.5, in: tab), 35)
    }

    // MARK: - Timeline-heading match jumps (need a selected tab)

    private func selectTab(_ tab: LogTab) {
        viewModel.openTabs = [tab]
        viewModel.selectedTabID = tab.id
        // Cancel the live-tail task the selection kicked off so it can't mutate state.
        viewModel.stopLiveTailing()
    }

    func testJumpToNextMatchAdvancesAndWraps() {
        var tab = makeTab(lineCount: 100)
        let ruleID = UUID()
        tab.timelineActiveRuleIDs = [ruleID]
        tab.timelineMatches = [[10, 20, 30]]
        let tabID = tab.id
        selectTab(tab)

        viewModel.jumpToNextMatch(forRuleID: ruleID)
        XCTAssertEqual(viewModel.timelineCurrentLineByTab[tabID], 10)
        viewModel.jumpToNextMatch(forRuleID: ruleID)
        XCTAssertEqual(viewModel.timelineCurrentLineByTab[tabID], 20)
        viewModel.jumpToNextMatch(forRuleID: ruleID)
        XCTAssertEqual(viewModel.timelineCurrentLineByTab[tabID], 30)
        // Past the last match → wrap to the first.
        viewModel.jumpToNextMatch(forRuleID: ruleID)
        XCTAssertEqual(viewModel.timelineCurrentLineByTab[tabID], 10)
    }

    func testJumpToPreviousMatchWrapsToLast() {
        var tab = makeTab(lineCount: 100)
        let ruleID = UUID()
        tab.timelineActiveRuleIDs = [ruleID]
        tab.timelineMatches = [[10, 20, 30]]
        let tabID = tab.id
        selectTab(tab)

        // Start at the first match, then step backwards → wraps to the last.
        viewModel.jumpToNextMatch(forRuleID: ruleID)
        XCTAssertEqual(viewModel.timelineCurrentLineByTab[tabID], 10)
        viewModel.jumpToPreviousMatch(forRuleID: ruleID)
        XCTAssertEqual(viewModel.timelineCurrentLineByTab[tabID], 30)
    }

    func testJumpWithUnknownRuleIsNoOp() {
        var tab = makeTab(lineCount: 100)
        let ruleID = UUID()
        tab.timelineActiveRuleIDs = [ruleID]
        tab.timelineMatches = [[10, 20, 30]]
        let tabID = tab.id
        selectTab(tab)

        viewModel.jumpToNextMatch(forRuleID: UUID()) // rule not in the timeline
        XCTAssertNil(viewModel.timelineCurrentLineByTab[tabID])
    }
}
