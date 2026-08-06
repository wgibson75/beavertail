//
//  LogViewModelHistoryTests.swift
//  BeaverTailTests
//
//  Item 14: filter-history and recent-files dedup / truncation / persistence.
//
//  These exercise real `LogViewModel` methods, so the test snapshots and restores
//  the UserDefaults keys and the `RecentFilesTracker` singleton they touch, keeping
//  the developer's actual saved state intact.
//

import XCTest
@testable import BeaverTail

@MainActor
final class LogViewModelHistoryTests: XCTestCase {

    private let filterKey = "saved_filter_history_v1"
    private let recentKey = "saved_recent_files_v1"
    private let sessionKey = "saved_session_bookmarks_v2"

    private var savedDefaults: [String: Any?] = [:]
    private var savedRecentFiles: [RecentFile] = []
    private var tempURLs: [URL] = []
    private var viewModel: LogViewModel!

    override func setUp() {
        super.setUp()
        // Snapshot and clear the persisted state so each test starts clean.
        for key in [filterKey, recentKey, sessionKey] {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        savedRecentFiles = RecentFilesTracker.shared.recentFiles
        RecentFilesTracker.shared.recentFiles = []
        viewModel = LogViewModel()
    }

    override func tearDown() {
        for (key, value) in savedDefaults {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        RecentFilesTracker.shared.recentFiles = savedRecentFiles
        for url in tempURLs { removeTempFile(url) }
        tempURLs = []
        viewModel = nil
        super.tearDown()
    }

    private func makeTempFile() -> URL {
        let url = (try? writeTempFile("log line")) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).log")
        tempURLs.append(url)
        return url
    }

    // MARK: - Filter history — Happy path

    func testFilterHistoryInsertsAtFront() {
        viewModel.addToFilterHistory("first")
        viewModel.addToFilterHistory("second")
        XCTAssertEqual(viewModel.filterHistory, ["second", "first"])
    }

    // MARK: - Filter history — Edge cases & Boundaries

    func testFilterHistoryDeduplicatesAndMovesToFront() {
        viewModel.addToFilterHistory("a")
        viewModel.addToFilterHistory("b")
        viewModel.addToFilterHistory("a")
        XCTAssertEqual(viewModel.filterHistory, ["a", "b"])
    }

    func testFilterHistoryCapsAtFifty() {
        for i in 0..<60 { viewModel.addToFilterHistory("p\(i)") }
        XCTAssertEqual(viewModel.filterHistory.count, 50)
        XCTAssertEqual(viewModel.filterHistory.first, "p59")
        XCTAssertTrue(viewModel.filterHistory.contains("p10"))
        XCTAssertFalse(viewModel.filterHistory.contains("p9"))
    }

    func testEmptyPatternIsIgnored() {
        viewModel.addToFilterHistory("only")
        viewModel.addToFilterHistory("")
        XCTAssertEqual(viewModel.filterHistory, ["only"])
    }

    // MARK: - Filter history — persistence & failure modes

    func testClearFilterHistory() {
        viewModel.addToFilterHistory("x")
        viewModel.clearFilterHistory()
        XCTAssertTrue(viewModel.filterHistory.isEmpty)
        XCTAssertEqual(viewModel.filterHistoryData, "")
    }

    func testFilterHistorySaveLoadRoundTrip() {
        viewModel.addToFilterHistory("x")
        viewModel.addToFilterHistory("y")
        viewModel.filterHistory = []
        viewModel.loadFilterHistory()
        XCTAssertEqual(viewModel.filterHistory, ["y", "x"])
    }

    func testFilterHistoryMalformedDataLoadsSafely() {
        viewModel.filterHistoryData = "not-json"
        viewModel.filterHistory = []
        viewModel.loadFilterHistory() // must not crash
        XCTAssertEqual(viewModel.filterHistory, [])
    }

    // MARK: - Recent files — Happy path

    func testRecentFileInsertsAtFront() {
        let fileA = makeTempFile()
        let fileB = makeTempFile()
        viewModel.addToRecentFiles(fileA)
        viewModel.addToRecentFiles(fileB)
        XCTAssertEqual(viewModel.recentFiles.first?.name, fileB.lastPathComponent)
        XCTAssertEqual(viewModel.recentFiles.count, 2)
    }

    // MARK: - Recent files — Edge cases & Boundaries

    func testRecentFilesDeduplicateByName() {
        let file = makeTempFile()
        viewModel.addToRecentFiles(file)
        viewModel.addToRecentFiles(file)
        XCTAssertEqual(viewModel.recentFiles.count, 1)
        XCTAssertEqual(viewModel.recentFiles.first?.name, file.lastPathComponent)
    }

    func testRecentFilesCapAtTen() {
        var urls: [URL] = []
        for _ in 0..<12 { urls.append(makeTempFile()) }
        for url in urls { viewModel.addToRecentFiles(url) }
        XCTAssertEqual(viewModel.recentFiles.count, 10)
        XCTAssertEqual(viewModel.recentFiles.first?.name, urls.last?.lastPathComponent)
        // The two oldest entries were dropped.
        XCTAssertFalse(viewModel.recentFiles.contains { $0.name == urls[0].lastPathComponent })
        XCTAssertFalse(viewModel.recentFiles.contains { $0.name == urls[1].lastPathComponent })
    }

    // MARK: - Recent files — persistence & failure modes

    func testClearRecentFiles() {
        viewModel.addToRecentFiles(makeTempFile())
        viewModel.clearRecentFiles()
        XCTAssertTrue(viewModel.recentFiles.isEmpty)
        XCTAssertEqual(viewModel.recentFilesData, "")
    }

    func testRecentFilesSaveLoadRoundTrip() {
        let fileA = makeTempFile()
        let fileB = makeTempFile()
        viewModel.addToRecentFiles(fileA)
        viewModel.addToRecentFiles(fileB)
        RecentFilesTracker.shared.recentFiles = []
        viewModel.loadRecentFiles()
        XCTAssertEqual(viewModel.recentFiles.count, 2)
        XCTAssertEqual(viewModel.recentFiles.first?.name, fileB.lastPathComponent)
    }

    func testRecentFilesMalformedDataLoadsSafely() {
        viewModel.recentFilesData = "not-json"
        RecentFilesTracker.shared.recentFiles = []
        viewModel.loadRecentFiles() // must not crash
        XCTAssertTrue(viewModel.recentFiles.isEmpty)
    }
}
