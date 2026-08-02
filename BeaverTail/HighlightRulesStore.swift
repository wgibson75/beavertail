//
//  HighlightRulesStore.swift
//  BeaverTail
//

import Combine
import Foundation

/// A dedicated, lightweight `ObservableObject` that owns the highlight rules.
///
/// The Highlight Filters window observes *this* store rather than the whole
/// `LogViewModel`. That way its rules list only re-renders when the rules
/// themselves change — not on every unrelated `LogViewModel` update (e.g. the
/// frequent `openTabs` / minimap / highlight-generation republishes). Those
/// unrelated redraws were interrupting in-progress drag-and-drop reordering of
/// filters.
final class HighlightRulesStore: ObservableObject {
    /// Invoked **synchronously** immediately after `rules` changes. `LogViewModel`
    /// uses this to persist and regenerate highlight data with the exact same
    /// timing as its original `didSet` — no main-queue deferral, so a highlight
    /// scan starts instantly rather than queuing behind other main-thread work
    /// (which noticeably delayed the first highlights on very large logs).
    var onRulesChanged: (() -> Void)?

    /// Invoked when only group metadata (label/enabled/order) changes and the
    /// rules themselves are untouched. `LogViewModel` uses this to *persist*
    /// without kicking off a (potentially expensive) highlight rescan — a mere
    /// group re-label should never rescan a huge log.
    var onGroupsChanged: (() -> Void)?

    @Published var rules: [HighlightRule] = [] {
        didSet {
            recordUndoSnapshot(previousRules: oldValue, previousGroups: groups)
            preserveEmptiedGroupPositions(previousRules: oldValue)
            onRulesChanged?()
        }
    }

    /// Optional groupings for the rules. Membership is stored on each rule via
    /// `HighlightRule.groupID`; this array holds each group's metadata (label,
    /// enabled state) and, for empty groups, keeps them alive as drop targets.
    @Published var groups: [HighlightGroup] = [] {
        didSet {
            recordUndoSnapshot(previousRules: rules, previousGroups: oldValue)
            onGroupsChanged?()
        }
    }

    // MARK: - Undo (⌘Z)

    /// A combined snapshot of the filters + groups taken *before* a change.
    private struct Snapshot {
        let rules: [HighlightRule]
        let groups: [HighlightGroup]
    }

    /// Up to the last 50 changes, newest last.
    private var undoStack: [Snapshot] = []
    private let maxUndoDepth = 50
    /// Coalesces the `rules`/`groups` writes of a single logical operation (e.g.
    /// deleting a group mutates both) into one undo step per run-loop tick.
    private var snapshotTakenThisTick = false
    /// Suppresses snapshotting while an undo is being applied.
    private var isApplyingUndo = false
    /// Set immediately before a text-edit mutation (e.g. typing a group name).
    private var pendingTextEditKey: String?
    /// The key of the text-edit run currently in progress; successive edits with
    /// the same key collapse into one undo step so ⌘Z removes the whole edit.
    private var activeTextEditKey: String?

    var canUndo: Bool { !undoStack.isEmpty }

    /// Pins any group that a rules change just left empty to the display position it
    /// occupied, so it doesn't jump to the top of the list. The anchor is the nearest
    /// still-existing rule that preceded the group's (now-removed) block; `nil` when the
    /// group sat at the very top. Runs synchronously within the same change so the undo
    /// snapshot (already taken) and persistence coalesce into one step.
    private func preserveEmptiedGroupPositions(previousRules: [HighlightRule]) {
        guard !isApplyingUndo else { return }

        let newGroupedIDs = Set(rules.compactMap { $0.groupID })
        let survivingRuleIDs = Set(rules.map { $0.id })

        // First-member index of each group in the PREVIOUS order (so we know where each
        // group's block used to start).
        var firstIndex: [UUID: Int] = [:]
        for (idx, rule) in previousRules.enumerated() {
            if let gid = rule.groupID, firstIndex[gid] == nil { firstIndex[gid] = idx }
        }

        for gi in groups.indices where !newGroupedIDs.contains(groups[gi].id) {
            // Only pin groups that JUST became empty (had a member previously).
            guard let start = firstIndex[groups[gi].id] else { continue }
            // Walk back to the nearest rule that still exists after the change.
            var anchor: UUID?
            var j = start - 1
            while j >= 0 {
                let candidate = previousRules[j].id
                if survivingRuleIDs.contains(candidate) { anchor = candidate; break }
                j -= 1
            }
            if groups[gi].anchorAfterRuleID != anchor {
                groups[gi].anchorAfterRuleID = anchor
            }
        }
    }

    /// Marks the next `rules`/`groups` mutation as part of an in-progress text
    /// edit (e.g. typing a group name). Successive keystrokes sharing `key` are
    /// collapsed so a single ⌘Z removes the whole edit rather than one character.
    func willEditText(key: String) {
        pendingTextEditKey = key
    }

    private func pushSnapshot(_ snapshot: Snapshot) {
        undoStack.append(snapshot)
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
    }

    private func recordUndoSnapshot(previousRules: [HighlightRule], previousGroups: [HighlightGroup]) {
        guard !isApplyingUndo else { return }

        if let key = pendingTextEditKey {
            pendingTextEditKey = nil
            // Continuation of the same field's edit → keep the single existing step.
            if key == activeTextEditKey { return }
            // First edit of this field → snapshot the pre-edit state and remember it.
            activeTextEditKey = key
            pushSnapshot(Snapshot(rules: previousRules, groups: previousGroups))
            return
        }

        // Any non-text-edit change ends the current text-edit run.
        activeTextEditKey = nil

        guard !snapshotTakenThisTick else { return }
        snapshotTakenThisTick = true
        pushSnapshot(Snapshot(rules: previousRules, groups: previousGroups))
        DispatchQueue.main.async { [weak self] in self?.snapshotTakenThisTick = false }
    }

    /// Restores the most recent snapshot. Restoring both arrays counts as a single
    /// undo (it is not itself pushed onto the stack).
    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        activeTextEditKey = nil
        isApplyingUndo = true
        rules = snapshot.rules
        groups = snapshot.groups
        DispatchQueue.main.async { [weak self] in self?.isApplyingUndo = false }
    }

    /// Clears the undo history (used after the initial load so the app's starting
    /// state can't be "undone" away).
    func resetUndoHistory() {
        undoStack.removeAll()
        snapshotTakenThisTick = false
        isApplyingUndo = false
        pendingTextEditKey = nil
        activeTextEditKey = nil
    }
}
