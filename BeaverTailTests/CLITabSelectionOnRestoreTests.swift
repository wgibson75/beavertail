//
//  CLITabSelectionOnRestoreTests.swift
//  BeaverTailTests
//
//  Regression coverage for launching with a log file argument (via the `btail`
//  CLI / `open -a BeaverTail file.log`). At cold launch the CLI file loads
//  synchronously and selects its tab, while session restore is dispatched
//  asynchronously and therefore runs afterwards. Session restore used to
//  unconditionally override `selectedTabID` with the previously-active restored
//  tab, so the CLI-opened log was loaded but a *different* tab ended up selected.
//  These tests pin that a selection already established at launch (the CLI file)
//  survives session restore.
//

import XCTest
@testable import BeaverTail

@MainActor
final class CLITabSelectionOnRestoreTests: XCTestCase {

    private var defaultsSnapshot: [String: Any?] = [:]
    private var viewModel: LogViewModel!
    private var tempURLs: [URL] = []

    override func setUp() {
        super.setUp()
        defaultsSnapshot = PersistedDefaults.clear()
    }

    override func tearDown() {
        viewModel?.stopLiveTailing()
        viewModel = nil
        for url in tempURLs { removeTempFile(url) }
        tempURLs = []
        PersistedDefaults.restore(defaultsSnapshot)
        super.tearDown()
    }

    private func makeTempFile() throws -> URL {
        let url = try writeTempFile("cli log line\nsecond line")
        tempURLs.append(url)
        return url
    }

    /// Mirrors the launch sequence: a CLI file is opened (and selected) first, then
    /// a saved session whose active tab is a *different* file is restored. The CLI
    /// tab must remain selected.
    func testCLIOpenedTabStaysSelectedAfterSessionRestore() throws {
        // Saved session of two files, the second previously active.
        let savedURLs = try (0..<2).map { _ in try makeTempFile() }
        let metadata: [SavedTabMetadata] = try savedURLs.enumerated().map { idx, url in
            SavedTabMetadata(
                bookmarkBase64: try SessionStore.makeBookmark(for: url),
                filterPattern: "",
                isSelected: idx == 1,       // the second saved tab was active
                markedIndices: [],
                isCaseInsensitive: true,
                followTail: true
            )
        }
        let encoded = try XCTUnwrap(SessionStore.encode(metadata))
        UserDefaults.standard.set(encoded, forKey: "saved_session_bookmarks_v2")

        viewModel = LogViewModel()

        // Simulate the CLI file-open that happens at launch before restore runs.
        let cliURL = try makeTempFile()
        viewModel.loadNewTab(from: cliURL)
        let cliTabID = try XCTUnwrap(viewModel.selectedTabID)

        // Now session restore runs (as it does asynchronously at launch).
        viewModel.loadSavedTabsSession()

        // All three files are present (CLI tab + two restored tabs)...
        XCTAssertEqual(viewModel.openTabs.count, 3)

        // ...and the CLI-opened tab remains selected, not the previously-active one.
        XCTAssertEqual(viewModel.selectedTabID, cliTabID,
                       "The CLI-opened tab must stay selected after session restore")

        // The CLI tab is also the one the strip is asked to reveal.
        XCTAssertEqual(viewModel.tabToRevealID, cliTabID,
                       "Restore should reveal the CLI-selected tab")
    }

    /// When the CLI file is ALSO part of the saved session, restore must not add a
    /// duplicate and must keep the CLI tab selected.
    func testCLIFileAlsoInSessionIsNotDuplicatedAndStaysSelected() throws {
        let cliURL = try makeTempFile()
        let otherURL = try makeTempFile()

        // Saved session contains both files; the OTHER file was previously active.
        let metadata: [SavedTabMetadata] = try [otherURL, cliURL].enumerated().map { idx, url in
            SavedTabMetadata(
                bookmarkBase64: try SessionStore.makeBookmark(for: url),
                filterPattern: "",
                isSelected: idx == 0,       // the other file was active
                markedIndices: [],
                isCaseInsensitive: true,
                followTail: true
            )
        }
        let encoded = try XCTUnwrap(SessionStore.encode(metadata))
        UserDefaults.standard.set(encoded, forKey: "saved_session_bookmarks_v2")

        viewModel = LogViewModel()
        viewModel.loadNewTab(from: cliURL)
        let cliTabID = try XCTUnwrap(viewModel.selectedTabID)

        viewModel.loadSavedTabsSession()

        // Two tabs total — the CLI file is not re-added by restore.
        XCTAssertEqual(viewModel.openTabs.count, 2)
        let cliMatches = viewModel.openTabs.filter {
            $0.fileURL.standardizedFileURL == cliURL.standardizedFileURL
        }
        XCTAssertEqual(cliMatches.count, 1, "The CLI file must not be duplicated")

        // The CLI tab stays selected.
        XCTAssertEqual(viewModel.selectedTabID, cliTabID)
    }

    /// Without any launch-time selection, restore still honours the saved active tab.
    func testRestoreHonoursSavedSelectionWhenNoCLIFile() throws {
        let urls = try (0..<2).map { _ in try makeTempFile() }
        let metadata: [SavedTabMetadata] = try urls.enumerated().map { idx, url in
            SavedTabMetadata(
                bookmarkBase64: try SessionStore.makeBookmark(for: url),
                filterPattern: "",
                isSelected: idx == 1,
                markedIndices: [],
                isCaseInsensitive: true,
                followTail: true
            )
        }
        let encoded = try XCTUnwrap(SessionStore.encode(metadata))
        UserDefaults.standard.set(encoded, forKey: "saved_session_bookmarks_v2")

        viewModel = LogViewModel()
        viewModel.loadSavedTabsSession()

        let secondURL = try XCTUnwrap(urls.last).standardizedFileURL
        let secondTab = try XCTUnwrap(
            viewModel.openTabs.first { $0.fileURL.standardizedFileURL == secondURL }
        )
        XCTAssertEqual(viewModel.selectedTabID, secondTab.id,
                       "With no CLI file, the saved active tab is selected")
    }
}
