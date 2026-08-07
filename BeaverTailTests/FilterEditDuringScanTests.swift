//
//  FilterEditDuringScanTests.swift
//  BeaverTailTests
//
//  Regression coverage for changing the Filter field while a filter scan is
//  still in flight (e.g. right after a large restored log finishes loading and
//  its saved filter is being applied). The asynchronous load-/scan-completion
//  handlers used to call `syncCurrentFilterPattern()`, which force-reset
//  `currentFilterPattern` (the Filter field binding) back to the tab's applied
//  pattern — discarding a new pattern the user was typing. Submitting then
//  re-applied the OLD pattern and the field visibly reverted. The completion
//  handlers now use `syncTabOptions()`, which never touches the filter text.
//

import XCTest
@testable import BeaverTail

@MainActor
final class FilterEditDuringScanTests: XCTestCase {

    private var defaultsSnapshot: [String: Any?] = [:]
    private var viewModel: LogViewModel!
    private var tempURLs: [URL] = []
    private var tabID: UUID!

    /// Even indices contain "alpha", odd indices contain "beta".
    private let lines: [String] = (0..<40).map { $0.isMultiple(of: 2) ? "alpha \($0)" : "beta \($0)" }
    private var alphaIndices: [Int] { Array(stride(from: 0, to: lines.count, by: 2)) }
    private var betaIndices: [Int] { Array(stride(from: 1, to: lines.count, by: 2)) }

    override func setUp() {
        super.setUp()
        defaultsSnapshot = PersistedDefaults.clear()
        viewModel = LogViewModel()

        let url = (try? writeTempFile("filter-edit")) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("filter-edit-\(UUID().uuidString).log")
        tempURLs.append(url)
        var tab = LogTab(name: "filter-edit", fileURL: url, content: LogContent.fromLines(lines))
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

    /// Pumps the run loop until `condition` holds; the filter scan delivers its
    /// results asynchronously via `DispatchQueue.main.async`.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
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

    /// Editing the Filter field while the first filter's scan is still running
    /// must not be reverted when that scan completes, and submitting must apply
    /// the NEW pattern.
    func testEditingFilterDuringInFlightScanIsNotReverted() {
        // The "original" filter, as re-applied when a restored log finishes loading.
        viewModel.applyFilter(with: "alpha")
        XCTAssertEqual(tab.filterPattern, "alpha")
        XCTAssertTrue(viewModel.progressTracker.isFiltering)

        // The user types a different pattern into the Filter field while the
        // "alpha" scan is still in flight (its main-queue completion has not run).
        viewModel.currentFilterPattern = "beta"

        // Let the in-flight "alpha" scan complete. Its completion must leave the
        // user's typed-ahead field untouched.
        waitUntil { self.viewModel.progressTracker.isFiltering == false }
        XCTAssertEqual(viewModel.currentFilterPattern, "beta",
                       "A filter typed while a scan runs must survive the scan's completion")

        // Submitting the field now applies the NEW pattern — not the old one.
        viewModel.applyFilter(with: viewModel.currentFilterPattern)
        XCTAssertEqual(tab.filterPattern, "beta")
        XCTAssertEqual(viewModel.currentActiveFilterPattern, "beta")

        waitUntil { self.viewModel.progressTracker.isFiltering == false }
        XCTAssertEqual(tab.filteredIndices, betaIndices,
                       "The bottom pane should reflect the newly-supplied filter")
    }

    /// The options-only sync used by the completion handlers must preserve the
    /// filter text while still mirroring the tab's Aa / Follow options.
    func testSyncTabOptionsPreservesFilterFieldText() {
        viewModel.currentFilterPattern = "in-progress-edit"
        if let idx = viewModel.openTabs.firstIndex(where: { $0.id == tabID }) {
            viewModel.openTabs[idx].isCaseInsensitive = false
            viewModel.openTabs[idx].followTail = false
        }

        viewModel.syncTabOptions()

        XCTAssertEqual(viewModel.currentFilterPattern, "in-progress-edit")
        XCTAssertFalse(viewModel.isCaseInsensitive)
        XCTAssertFalse(viewModel.followTail)
    }
}
