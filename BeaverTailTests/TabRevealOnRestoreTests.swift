//
//  TabRevealOnRestoreTests.swift
//  BeaverTailTests
//
//  Regression coverage for restoring a session where the previously-active tab
//  sits off the right-hand edge of the tab strip (all other tabs are to its
//  left). On launch the strip must scroll that tab into view so the user can see
//  which log is currently visible. The view model signals this by setting
//  `tabToRevealID`; the tab strip's `ScrollViewReader` consumes it (see
//  `ContentView.revealSelectedTab`). This test asserts the signal is raised for
//  the correct (previously-active, off-screen) tab.
//

import XCTest
@testable import BeaverTail

@MainActor
final class TabRevealOnRestoreTests: XCTestCase {

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
        let url = try writeTempFile("session log line\nsecond line")
        tempURLs.append(url)
        return url
    }

    func testRestoreRequestsRevealingPreviouslyActiveOffScreenTab() throws {
        // Three restored tabs; the previously-active tab is the LAST one, so on
        // launch it sits off the right-hand edge behind the other two.
        let urls = try (0..<3).map { _ in try makeTempFile() }
        let metadata: [SavedTabMetadata] = try urls.enumerated().map { idx, url in
            SavedTabMetadata(
                bookmarkBase64: try SessionStore.makeBookmark(for: url),
                filterPattern: "",
                isSelected: idx == urls.count - 1,   // the last tab was active
                markedIndices: [],
                isCaseInsensitive: true,
                followTail: true
            )
        }
        let encoded = try XCTUnwrap(SessionStore.encode(metadata))
        UserDefaults.standard.set(encoded, forKey: "saved_session_bookmarks_v2")

        viewModel = LogViewModel()
        viewModel.loadSavedTabsSession()

        // All three tabs are restored, in their saved order.
        XCTAssertEqual(viewModel.openTabs.count, 3)

        let lastURL = try XCTUnwrap(urls.last).standardizedFileURL
        let lastTab = try XCTUnwrap(
            viewModel.openTabs.first { $0.fileURL.standardizedFileURL == lastURL }
        )

        // The previously-active (last / off-screen) tab is selected...
        XCTAssertEqual(viewModel.selectedTabID, lastTab.id)
        XCTAssertEqual(viewModel.openTabs.last?.id, lastTab.id,
                       "The selected tab should be the last one — off the right edge")

        // ...and the tab strip is asked to scroll it into view.
        XCTAssertEqual(viewModel.tabToRevealID, lastTab.id,
                       "Restore must request revealing the previously-active tab")
    }
}
