//
//  HighlightRulesStoreTests.swift
//  BeaverTailTests
//
//  Item 7: undo/redo snapshotting, stack cap, text-edit coalescing and
//  emptied-group position preservation.
//

import XCTest
@testable import BeaverTail

@MainActor
final class HighlightRulesStoreTests: XCTestCase {

    // The store coalesces all `rules`/`groups` writes within one run-loop tick into
    // a single undo step (resetting a flag via `DispatchQueue.main.async`). Draining
    // the main queue between mutations lets each become its own distinct undo step.
    private func drainMainQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    private func makeRule(_ pattern: String, groupID: UUID? = nil) -> HighlightRule {
        HighlightRule(
            pattern: pattern,
            foregroundColorHex: "FFFFFF",
            backgroundColorHex: "FFFF00",
            groupID: groupID
        )
    }

    // MARK: - Happy path

    func testEditingRulesEnablesUndoAndUndoRestores() {
        let store = HighlightRulesStore()
        XCTAssertFalse(store.canUndo)
        store.rules = [makeRule("alpha")]
        XCTAssertTrue(store.canUndo)

        store.undo()
        XCTAssertEqual(store.rules, [])
        XCTAssertFalse(store.canUndo)
    }

    func testMultipleUndoStepsAppliedInReverseOrder() async {
        let store = HighlightRulesStore()
        let ruleA = makeRule("A")
        let ruleB = makeRule("B")

        store.rules = [ruleA]
        await drainMainQueue()
        store.rules = [ruleA, ruleB]
        await drainMainQueue()

        XCTAssertEqual(store.rules.count, 2)
        store.undo()
        XCTAssertEqual(store.rules, [ruleA])
        store.undo()
        XCTAssertEqual(store.rules, [])
    }

    // MARK: - Edge cases & Boundaries

    func testUndoStackIsCappedAtFifty() async {
        let store = HighlightRulesStore()
        // 55 distinct, separately-ticked mutations → only the last 50 are retained.
        for i in 0..<55 {
            store.rules = [makeRule("p\(i)")]
            await drainMainQueue()
        }

        var undoCount = 0
        while store.canUndo {
            store.undo()
            undoCount += 1
        }
        XCTAssertEqual(undoCount, 50)
    }

    func testResetUndoHistoryClearsStack() {
        let store = HighlightRulesStore()
        store.rules = [makeRule("A")]
        XCTAssertTrue(store.canUndo)
        store.resetUndoHistory()
        XCTAssertFalse(store.canUndo)
    }

    func testTextEditKeystrokesCollapseIntoOneUndoStep() async {
        let store = HighlightRulesStore()
        let group = HighlightGroup(id: UUID(), label: "")
        store.groups = [group]
        await drainMainQueue()

        // Three keystrokes on the same field, each marked with the same edit key,
        // must collapse into a single undo step.
        for text in ["a", "ab", "abc"] {
            store.willEditText(key: "group-label")
            store.groups[0].label = text
        }
        XCTAssertEqual(store.groups[0].label, "abc")

        // One undo reverts the entire typed edit back to the empty label.
        store.undo()
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups[0].label, "")

        // A second undo removes the group creation itself.
        store.undo()
        XCTAssertTrue(store.groups.isEmpty)
    }

    // MARK: - Failure modes

    func testUndoOnEmptyStackIsNoOp() {
        let store = HighlightRulesStore()
        XCTAssertFalse(store.canUndo)
        store.undo() // must not crash
        XCTAssertEqual(store.rules, [])
        XCTAssertEqual(store.groups, [])
    }

    // MARK: - State: emptied-group position preservation

    func testEmptiedGroupIsAnchoredToPrecedingRule() {
        let store = HighlightRulesStore()
        let gid = UUID()
        let r1 = makeRule("r1")
        let r2 = makeRule("r2", groupID: gid)
        let r3 = makeRule("r3")
        store.groups = [HighlightGroup(id: gid, label: "G")]
        store.rules = [r1, r2, r3]

        // Remove the group's only member: the now-empty group should pin itself to
        // the nearest surviving preceding rule (r1) so it keeps its list position.
        store.rules = [r1, r3]
        XCTAssertEqual(store.groups[0].anchorAfterRuleID, r1.id)
    }

    func testEmptiedGroupAtTopAnchorsToNil() {
        let store = HighlightRulesStore()
        let gid = UUID()
        let r2 = makeRule("r2", groupID: gid)
        let r3 = makeRule("r3")
        store.groups = [HighlightGroup(id: gid, label: "G")]
        store.rules = [r2, r3]

        // The group sat at the very top (no preceding rule) → anchor stays nil.
        store.rules = [r3]
        XCTAssertNil(store.groups[0].anchorAfterRuleID)
    }
}
