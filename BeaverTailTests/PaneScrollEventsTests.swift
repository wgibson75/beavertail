//
//  PaneScrollEventsTests.swift
//  BeaverTailTests
//
//  Roadmap item: UI notifications replaced with observable view-model state. The
//  pane-scroll commands that were broadcast through global NotificationCenter
//  channels are now typed `PaneScrollCommand`s published on the view model's own
//  `topPaneScrollEvents` / `bottomPaneScrollEvents` streams. These tests verify a
//  view-model action emits the expected command on the correct pane's stream.
//

import XCTest
import Combine
@testable import BeaverTail

@MainActor
final class PaneScrollEventsTests: XCTestCase {

    private var defaultsSnapshot: [String: Any?] = [:]
    private var viewModel: LogViewModel!
    private var tempURLs: [URL] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        defaultsSnapshot = PersistedDefaults.clear()
        viewModel = LogViewModel()
    }

    override func tearDown() {
        cancellables.removeAll()
        viewModel.stopLiveTailing()
        viewModel = nil
        for url in tempURLs { removeTempFile(url) }
        tempURLs = []
        PersistedDefaults.restore(defaultsSnapshot)
        super.tearDown()
    }

    private func makeTab(lineCount: Int) -> LogTab {
        let url = (try? writeTempFile("scroll")) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("scroll-\(UUID().uuidString).log")
        tempURLs.append(url)
        let lines = (0..<lineCount).map { "line\($0)" }
        return LogTab(name: "scroll", fileURL: url, content: LogContent.fromLines(lines))
    }

    private func selectTab(_ tab: LogTab) {
        viewModel.openTabs = [tab]
        viewModel.selectedTabID = tab.id
        // Cancel the live-tail task the selection kicked off so it can't mutate state.
        viewModel.stopLiveTailing()
    }

    // MARK: - Top pane stream

    func testTimelineHeadingJumpEmitsDirectTopPaneCommand() {
        var tab = makeTab(lineCount: 100)
        let ruleID = UUID()
        tab.timelineActiveRuleIDs = [ruleID]
        tab.timelineMatches = [[10, 20, 30]]
        selectTab(tab)

        var topReceived: [PaneScrollCommand] = []
        var bottomReceived: [PaneScrollCommand] = []
        viewModel.topPaneScrollEvents.sink { topReceived.append($0) }.store(in: &cancellables)
        viewModel.bottomPaneScrollEvents.sink { bottomReceived.append($0) }.store(in: &cancellables)

        // Jumps to the first match (line 10); emits synchronously on the top stream.
        viewModel.jumpToNextMatch(forRuleID: ruleID)

        guard case .direct(let request)? = topReceived.first else {
            return XCTFail("expected a .direct top-pane command, got \(topReceived)")
        }
        // No lines hidden → the top-pane row equals the original line index.
        XCTAssertEqual(request.lineIndex, 10)
        // Heading navigation must never trigger horizontal auto-scroll.
        XCTAssertFalse(request.allowsHorizontalScroll)
        // The command must go to the top pane only, not the bottom pane.
        XCTAssertTrue(bottomReceived.isEmpty)
    }

    // MARK: - Bottom pane stream

    func testMarkBlockJumpEmitsBottomPaneRowCommand() {
        // A filtered tab whose displayed rows are the marked lines. Jumping to a mark
        // block scrolls the bottom pane to that row via the bottom stream.
        var tab = makeTab(lineCount: 100)
        tab.filterPattern = "line"
        tab.markedIndices = [10, 40, 70]
        tab.filteredIndices = [10, 40, 70]
        tab.displayedIndices = [10, 40, 70]
        selectTab(tab)

        var bottomReceived: [PaneScrollCommand] = []
        viewModel.bottomPaneScrollEvents.sink { bottomReceived.append($0) }.store(in: &cancellables)

        // Navigate to the next mark block — routes through the bottom-pane stream.
        viewModel.navigateToNextMarkBlock()

        let sawRowCommand = bottomReceived.contains { command in
            if case .toRow = command { return true }
            return false
        }
        XCTAssertTrue(sawRowCommand, "expected a .toRow bottom-pane command, got \(bottomReceived)")
    }
}
