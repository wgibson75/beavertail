//
//  CompareTests.swift
//  BeaverTailTests
//
//  Item 16: tab marking / sequencing and the end-to-end "Find Unique Lines"
//  pipeline (which also exercises the private markedTabsInOrder / comparisonInputs
//  / resolveSources / ensureUniqueLinesTab / populateUniqueLinesTab helpers).
//

import XCTest
@testable import BeaverTail

@MainActor
final class CompareTests: XCTestCase {

    private var defaultsSnapshot: [String: Any?] = [:]
    private var viewModel: LogViewModel!
    private var tempURLs: [URL] = []

    override func setUp() {
        super.setUp()
        defaultsSnapshot = PersistedDefaults.clear()
        viewModel = LogViewModel()
    }

    override func tearDown() {
        viewModel.cancelUniqueLinesGeneration()
        viewModel.stopLiveTailing()
        viewModel = nil
        for url in tempURLs { removeTempFile(url) }
        tempURLs = []
        PersistedDefaults.restore(defaultsSnapshot)
        super.tearDown()
    }

    private func makeTab(name: String, lines: [String]? = nil) -> LogTab {
        let url = (try? writeTempFile("compare")) ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("cmp-\(UUID().uuidString).log")
        tempURLs.append(url)
        var tab = LogTab(name: name, fileURL: url,
                         content: lines.map { LogContent.fromLines($0) })
        tab.isCurrentlyStreaming = false
        return tab
    }

    // MARK: - Marking — Happy path

    func testMarkTabAssignsIncreasingSequence() {
        let a = makeTab(name: "a"), b = makeTab(name: "b"), c = makeTab(name: "c")
        viewModel.openTabs = [a, b, c]

        viewModel.markTab(id: a.id, as: .good)
        viewModel.markTab(id: b.id, as: .bad)
        viewModel.markTab(id: c.id, as: .good)

        XCTAssertEqual(viewModel.openTabs.first { $0.id == a.id }?.markSequence, 1)
        XCTAssertEqual(viewModel.openTabs.first { $0.id == b.id }?.markSequence, 2)
        XCTAssertEqual(viewModel.openTabs.first { $0.id == c.id }?.markSequence, 3)
    }

    func testGoodAndBadCounts() {
        let a = makeTab(name: "a"), b = makeTab(name: "b"), c = makeTab(name: "c")
        viewModel.openTabs = [a, b, c]
        viewModel.markTab(id: a.id, as: .good)
        viewModel.markTab(id: b.id, as: .bad)
        viewModel.markTab(id: c.id, as: .good)

        XCTAssertEqual(viewModel.goodLogCount, 2)
        XCTAssertEqual(viewModel.badLogCount, 1)
    }

    // MARK: - Marking — Edge cases & Boundaries

    func testCanFindUniqueLinesRequiresBothSides() {
        let a = makeTab(name: "a"), b = makeTab(name: "b")
        viewModel.openTabs = [a, b]
        XCTAssertFalse(viewModel.canFindUniqueLines)
        viewModel.markTab(id: a.id, as: .good)
        XCTAssertFalse(viewModel.canFindUniqueLines) // no bad yet
        viewModel.markTab(id: b.id, as: .bad)
        XCTAssertTrue(viewModel.canFindUniqueLines)
    }

    func testClearAllTabMarksResetsMarksAndSequences() {
        let a = makeTab(name: "a"), b = makeTab(name: "b")
        viewModel.openTabs = [a, b]
        viewModel.markTab(id: a.id, as: .good)
        viewModel.markTab(id: b.id, as: .bad)

        viewModel.clearAllTabMarks()
        XCTAssertEqual(viewModel.goodLogCount, 0)
        XCTAssertEqual(viewModel.badLogCount, 0)
        XCTAssertNil(viewModel.openTabs.first { $0.id == a.id }?.markSequence)
    }

    func testMarkTabWithNilClearsMark() {
        let a = makeTab(name: "a")
        viewModel.openTabs = [a]
        viewModel.markTab(id: a.id, as: .good)
        viewModel.markTab(id: a.id, as: nil)
        XCTAssertNil(viewModel.openTabs.first { $0.id == a.id }?.mark)
        XCTAssertNil(viewModel.openTabs.first { $0.id == a.id }?.markSequence)
    }

    // MARK: - Comparison pipeline — Happy path (end-to-end)

    func testFindUniqueLinesProducesBadOnlyLines() async {
        let good = makeTab(name: "good", lines: ["alpha", "beta"])
        let bad = makeTab(name: "bad", lines: ["beta", "gamma"])
        viewModel.openTabs = [good, bad]
        viewModel.markTab(id: good.id, as: .good)
        viewModel.markTab(id: bad.id, as: .bad)

        viewModel.findUniqueLines(preferring: .bad)
        await viewModel.uniqueLinesTask?.value

        let results = viewModel.openTabs.first { $0.isUniqueLinesTab }
        XCTAssertNotNil(results?.content)
        XCTAssertEqual(results?.content?.count, 1)
        XCTAssertEqual(results?.content?.line(at: 0), "gamma")
    }

    // MARK: - Comparison pipeline — State (single reused results tab)

    func testFindUniqueLinesReusesSingleResultsTab() async {
        let good = makeTab(name: "good", lines: ["alpha", "beta"])
        let bad = makeTab(name: "bad", lines: ["beta", "gamma"])
        viewModel.openTabs = [good, bad]
        viewModel.markTab(id: good.id, as: .good)
        viewModel.markTab(id: bad.id, as: .bad)

        viewModel.findUniqueLines(preferring: .bad)
        await viewModel.uniqueLinesTask?.value
        viewModel.findUniqueLines(preferring: .bad)
        await viewModel.uniqueLinesTask?.value

        let resultsTabs = viewModel.openTabs.filter { $0.isUniqueLinesTab }
        XCTAssertEqual(resultsTabs.count, 1, "the results tab must be reused, not duplicated")
        XCTAssertEqual(resultsTabs.first?.content?.line(at: 0), "gamma")
    }
}
