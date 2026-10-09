//
//  GroupReorderDragTests.swift
//  BeaverTailTests
//
//  Regression coverage for the Highlight Filters "a group can only be moved once" bug.
//
//  Root cause: the group header's `.onDrag` closure mutated SwiftUI `@State`
//  (`isDraggingGroup` / `draggingRuleIDs`) the moment a drag began. Mutating `@State`
//  from inside `.onDrag` invalidates the view mid-gesture, which on macOS leaves the
//  List's drag source broken — the group could be moved once and then not again until
//  the dialog was closed and reopened (which rebuilt the view and its `@State`).
//
//  The fix has two testable parts:
//
//   1. That transient drag bookkeeping now lives on `RulesDropController` (a plain
//      reference object), so `.onDrag` no longer touches `@State`. The
//      `testDropController…` cases drive repeated begin/end drags and assert the state
//      never gets stuck.
//
//   2. The reorder *logic* core of `performGroupDrop` was extracted into the pure
//      `HighlightSettingsView.rulesByMovingGroup(_:before:in:)`. The reorder cases drive
//      it through repeated moves and assert the resulting order every time, so a future
//      change that makes a second move a no-op (or corrupts the order) fails here.
//

import XCTest
@testable import BeaverTail

@MainActor
final class GroupReorderDragTests: XCTestCase {

    private func makeRule(_ pattern: String, groupID: UUID? = nil) -> HighlightRule {
        HighlightRule(
            pattern: pattern,
            foregroundColorHex: "FFFFFF",
            backgroundColorHex: "FFFF00",
            groupID: groupID
        )
    }

    /// Compact view of the rule order for readable assertions.
    private func patterns(_ rules: [HighlightRule]) -> [String] { rules.map(\.pattern) }

    // MARK: - Two groups, moved back and forth repeatedly

    func testGroupCanBeMovedDownThenBackUpRepeatedly() {
        let gA = UUID(), gB = UUID()
        let a1 = makeRule("a1", groupID: gA)
        let b1 = makeRule("b1", groupID: gB)

        var rules = [a1, b1] // order: A, B

        // Move A to the end (anchor = nil) -> B, A.
        rules = HighlightSettingsView.rulesByMovingGroup(gA, before: nil, in: rules)
        XCTAssertEqual(patterns(rules), ["b1", "a1"], "First move should put group A after B.")

        // Move A back to the top (anchor = b1) -> A, B. This is the move that used to be
        // impossible in the real UI.
        rules = HighlightSettingsView.rulesByMovingGroup(gA, before: b1.id, in: rules)
        XCTAssertEqual(patterns(rules), ["a1", "b1"], "Second, consecutive move should put group A back before B.")

        // And once more, to prove it's not a one-shot.
        rules = HighlightSettingsView.rulesByMovingGroup(gA, before: nil, in: rules)
        XCTAssertEqual(patterns(rules), ["b1", "a1"], "Third move should work exactly like the first.")
    }

    // MARK: - A group never splits another group

    func testMovingGroupSnapsToTheStartOfTheAnchorsBlock() {
        let gA = UUID(), gB = UUID()
        let a1 = makeRule("a1", groupID: gA)
        let b1 = makeRule("b1", groupID: gB)
        let b2 = makeRule("b2", groupID: gB)

        // order: B(b1,b2), A(a1). Move A before b2 — the anchor is inside group B, so A
        // must land at the START of B's block, not between b1 and b2.
        let rules = [b1, b2, a1]
        let moved = HighlightSettingsView.rulesByMovingGroup(gA, before: b2.id, in: rules)
        XCTAssertEqual(patterns(moved), ["a1", "b1", "b2"], "Group A should snap ahead of group B's whole block.")
    }

    // MARK: - A lone group amongst ungrouped rules

    func testGroupMovesAmongUngroupedRulesRepeatedly() {
        let gA = UUID()
        let a1 = makeRule("a1", groupID: gA)
        let u1 = makeRule("u1")
        let u2 = makeRule("u2")

        var rules = [a1, u1, u2] // group at the top

        // Move group A to the bottom (anchor = nil).
        rules = HighlightSettingsView.rulesByMovingGroup(gA, before: nil, in: rules)
        XCTAssertEqual(patterns(rules), ["u1", "u2", "a1"], "Group should move to the bottom.")

        // Move it back to the top (anchor = u1).
        rules = HighlightSettingsView.rulesByMovingGroup(gA, before: u1.id, in: rules)
        XCTAssertEqual(patterns(rules), ["a1", "u1", "u2"], "Group should move back to the top on the second move.")
    }

    // MARK: - Multi-rule groups keep their internal order

    func testMovingMultiRuleGroupPreservesMemberOrder() {
        let gA = UUID(), gB = UUID()
        let a1 = makeRule("a1", groupID: gA)
        let a2 = makeRule("a2", groupID: gA)
        let b1 = makeRule("b1", groupID: gB)

        let rules = [a1, a2, b1]
        let moved = HighlightSettingsView.rulesByMovingGroup(gA, before: nil, in: rules)
        XCTAssertEqual(patterns(moved), ["b1", "a1", "a2"], "Moving a group must keep its members contiguous and in order.")
    }

    // MARK: - Empty group is a no-op

    func testMovingEmptyGroupIsANoOp() {
        let gEmpty = UUID()
        let u1 = makeRule("u1")
        let u2 = makeRule("u2")

        let rules = [u1, u2]
        let moved = HighlightSettingsView.rulesByMovingGroup(gEmpty, before: u1.id, in: rules)
        XCTAssertEqual(patterns(moved), ["u1", "u2"], "A group with no member rules should leave the order unchanged.")
    }

    // MARK: - Transient drag bookkeeping lives off `@State`
    //
    // The actual "can only move a group once" bug was that `.onDrag` mutated SwiftUI
    // `@State` (`isDraggingGroup` / `draggingRuleIDs`), invalidating the view mid-drag and
    // breaking the List's drag source until the dialog was reopened. The fix moved that
    // bookkeeping onto `RulesDropController` (a plain reference object), so `.onDrag` no
    // longer touches `@State`. These tests pin that the controller tracks the drag type
    // correctly across *repeated* drags — a group, then another group, then rows — which
    // is exactly the sequence that used to fail.

    func testDropControllerTracksRepeatedGroupDragsWithoutGettingStuck() {
        let controller = RulesDropController()
        XCTAssertFalse(controller.isDraggingGroup)
        XCTAssertTrue(controller.draggingRuleIDs.isEmpty)

        // First group drag.
        controller.beginGroupDrag()
        XCTAssertTrue(controller.isDraggingGroup, "A group drag should mark isDraggingGroup.")
        XCTAssertTrue(controller.draggingRuleIDs.isEmpty, "A group drag carries no rule IDs.")

        controller.endDrag()
        XCTAssertFalse(controller.isDraggingGroup, "Ending the drag must reset the flag.")

        // Second, consecutive group drag must behave identically (the regression was that
        // the second move was impossible).
        controller.beginGroupDrag()
        XCTAssertTrue(controller.isDraggingGroup, "A second group drag must set isDraggingGroup again.")
        controller.endDrag()
        XCTAssertFalse(controller.isDraggingGroup)
    }

    func testDropControllerSwitchesBetweenGroupAndRuleDrags() {
        let controller = RulesDropController()
        let r1 = UUID(), r2 = UUID()

        controller.beginRuleDrag([r1, r2])
        XCTAssertFalse(controller.isDraggingGroup, "A rule drag is not a group drag.")
        XCTAssertEqual(controller.draggingRuleIDs, [r1, r2])

        controller.endDrag()
        XCTAssertTrue(controller.draggingRuleIDs.isEmpty, "Ending the drag clears the rule IDs.")

        controller.beginGroupDrag()
        XCTAssertTrue(controller.isDraggingGroup)
        XCTAssertTrue(controller.draggingRuleIDs.isEmpty, "Switching to a group drag clears any stale rule IDs.")
    }
}

// MARK: - Synthetic drag-reset click
//
// On macOS, SwiftUI's `.onDrag` row gesture stays stuck after a drop until the app
// dispatches a real mouse event — the user hit this as "I can't drag the group again until
// I click somewhere in the dialog." The fix (`DragAutoScroller.postDragResetClick`) posts a
// harmless synthetic click into the form's top padding (above the first control). These
// tests pin that the computed click location stays within that safe top region so it never
// triggers a control.
final class DragResetClickLocationTests: XCTestCase {

    func testClickLandsInTopPaddingAboveFirstControl() {
        // Content frame as reported in window base coords (origin bottom-left).
        let content = NSRect(x: 0, y: 0, width: 520, height: 600)
        let p = DragAutoScroller.dragResetClickLocation(inContentFrame: content)

        XCTAssertEqual(p.x, content.midX, accuracy: 0.001, "Click should be horizontally centred.")
        // Just inside the top edge: below the very top but within the form's ~12pt padding,
        // so it lands above the first control (the pattern field) and triggers nothing.
        XCTAssertLessThan(p.y, content.maxY, "Click must be inside the content, not on the edge.")
        XCTAssertGreaterThan(p.y, content.maxY - 12, "Click must stay within the top padding band.")
    }

    func testClickLocationTracksContentOrigin() {
        // A non-zero origin (e.g. inset content) must still place the click near the top.
        let content = NSRect(x: 40, y: 30, width: 400, height: 500)
        let p = DragAutoScroller.dragResetClickLocation(inContentFrame: content)
        XCTAssertEqual(p.x, content.midX, accuracy: 0.001)
        XCTAssertEqual(p.y, content.maxY - 6, accuracy: 0.001)
    }
}
