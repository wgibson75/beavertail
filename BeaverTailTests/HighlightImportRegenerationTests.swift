//
//  HighlightImportRegenerationTests.swift
//  BeaverTailTests
//
//  Regression coverage for importing highlight filters into a log that already
//  has a filter applied. Importing a grouped document assigns `groups` first and
//  `rules` second within the same run-loop tick. The `groups` write fires a
//  highlight regeneration while `rules` is still empty, which schedules a
//  *deferred* "no active rules" clear. That clear used to run *after* the
//  subsequent `rules` write had already set up the real match scan, wiping its
//  freshly-built `highlightMatches`/`activeRuleIDs` so the in-flight scan
//  discarded its results — the log stayed unhighlighted until a filter was
//  manually toggled. See `LogViewModel.generateHighlightData`.
//

import XCTest
@testable import BeaverTail

@MainActor
final class HighlightImportRegenerationTests: XCTestCase {

    private var defaultsSnapshot: [String: Any?] = [:]
    private var viewModel: LogViewModel!
    private var tempURLs: [URL] = []
    private var tabID: UUID!

    /// Lines 0, 2 and 4 contain "error"; the rest do not.
    private let lines = ["error 1", "info a", "error 2", "warn b", "error 3", "info c"]

    override func setUp() {
        super.setUp()
        defaultsSnapshot = PersistedDefaults.clear()
        viewModel = LogViewModel()

        let url = (try? writeTempFile("import")) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).log")
        tempURLs.append(url)
        var tab = LogTab(name: "import", fileURL: url, content: LogContent.fromLines(lines))
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

    /// Mimics the reported scenario: a ".*" filter is active, so every line is
    /// displayed in the bottom pane.
    private func applyMatchAllFilter() {
        guard let idx = viewModel.openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        viewModel.openTabs[idx].filterPattern = ".*"
        viewModel.openTabs[idx].filteredIndices = Array(0..<lines.count)
        viewModel.openTabs[idx].displayedIndices = Array(0..<lines.count)
    }

    /// Pumps the run loop until `condition` holds (the highlight scan delivers its
    /// results asynchronously via `DispatchQueue.main.async`).
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let exp = expectation(description: "condition met")
        func poll() {
            if condition() {
                exp.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        poll()
        wait(for: [exp], timeout: timeout)
    }

    // MARK: - The regression

    /// Importing an enabled group + enabled rule (groups written first, rules
    /// second) must highlight the matching lines without any manual toggle.
    func testImportingEnabledFiltersHighlightsMatchingLines() {
        XCTAssertTrue(viewModel.highlightRules.isEmpty, "Precondition: no rules on launch")
        applyMatchAllFilter()

        let group = HighlightGroup(label: "Imported", isEnabled: true)
        let rule = HighlightRule(
            pattern: "error",
            foregroundColorHex: "#FFFFFF",
            backgroundColorHex: "#FFFF00",
            isEnabled: true,
            groupID: group.id
        )

        // Exact write order used by `applyImportedDocument`.
        viewModel.highlightRulesStore.groups = [group]
        viewModel.highlightRulesStore.rules = [rule]

        waitUntil { self.tab.highlightMatches.first?.isEmpty == false }

        XCTAssertEqual(tab.activeRuleIDs, [rule.id])
        XCTAssertEqual(tab.highlightMatches.count, 1)
        XCTAssertEqual(tab.highlightMatches.first, [0, 2, 4],
                       "Lines containing \"error\" should be highlighted after import")
    }

    /// Guards the other side of the fix: when rules genuinely become empty, the
    /// deferred clear must still wipe the previous highlights.
    func testRemovingAllFiltersClearsHighlights() {
        applyMatchAllFilter()

        let rule = HighlightRule(
            pattern: "error",
            foregroundColorHex: "#FFFFFF",
            backgroundColorHex: "#FFFF00",
            isEnabled: true
        )
        viewModel.highlightRules = [rule]
        waitUntil { self.tab.highlightMatches.first?.isEmpty == false }

        // Remove every rule — highlights (and active rule tracking) must clear.
        viewModel.highlightRules = []
        waitUntil { self.tab.highlightMatches.isEmpty && self.tab.activeRuleIDs.isEmpty }

        XCTAssertTrue(tab.highlightMatches.isEmpty)
        XCTAssertTrue(tab.activeRuleIDs.isEmpty)
    }
}
