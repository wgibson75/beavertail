//
//  LogViewModel+LineVisibility.swift
//  BeaverTail
//
//  Line-visibility / time-period control: hiding lines above/below, marking out a
//  time period on the minimap, revealing all lines, and stepping back through the
//  history of narrowed ranges. Split out of LogViewModel to keep that file under
//  the SwiftLint file-length limit.
//

import AppKit
import Combine
import Foundation

extension LogViewModel {

    // MARK: - Hide / Show Lines

    /// Hides every line before `originalIndex` in the current tab (the selected line
    /// stays visible), updating the top pane, bottom pane, minimap and timeline.
    func hideLinesAbove(originalIndex: Int) {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        // Record the current range so a right-click can step back to it.
        pushVisibleBoundsHistory(for: index)
        openTabs[index].visibleLowerBound = originalIndex
        // Keep the bounds consistent if a "below" hide is already narrower.
        if let upper = openTabs[index].visibleUpperBound, upper < originalIndex {
            openTabs[index].visibleUpperBound = originalIndex
        }
        // The just-hidden line becomes the first visible line, so the current-line
        // indicator should now sit at the top of the (regenerated) minimap.
        applyLineVisibilityChange(for: index, tabID: tabID, selectedOriginalIndex: originalIndex)

        // The just-hidden line is now the first visible line: row 0 of the top pane
        // (a RangeLineProvider) and the first visible row of the bottom pane. Re-select
        // and pin it to the top of both panes so it doesn't appear to jump to a
        // different line. Deferred so the panes have rebuilt with the new range first.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: topPaneScrollToRowNotification, object: 0)
            NotificationCenter.default.post(name: bottomPaneScrollToRowNotification, object: 0)
        }
    }

    /// Hides every line after `originalIndex` in the current tab (the selected line
    /// stays visible), updating the top pane, bottom pane, minimap and timeline.
    func hideLinesBelow(originalIndex: Int) {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        // Record the current range so a right-click can step back to it.
        pushVisibleBoundsHistory(for: index)
        openTabs[index].visibleUpperBound = originalIndex
        if let lower = openTabs[index].visibleLowerBound, lower > originalIndex {
            openTabs[index].visibleLowerBound = originalIndex
        }
        // The just-hidden line becomes the last visible line, so keep the current-line
        // indicator pinned to it within the regenerated minimap.
        applyLineVisibilityChange(for: index, tabID: tabID, selectedOriginalIndex: originalIndex)
    }

    /// Restricts both panes to a time period marked out on the minimap by a
    /// click-drag-release, hiding every line that falls outside the dragged range.
    /// `fromFraction` and `toFraction` are the 0...1 minimap positions where the
    /// drag began and ended (order-independent). Uses the same hide/show plumbing
    /// as `hideLinesAbove`/`hideLinesBelow`, so the "Reset" context-menu item
    /// becomes available in both panes and restores all lines when chosen.
    func selectTimePeriod(fromFraction: CGFloat, toFraction: CGFloat) {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }),
              openTabs[index].content != nil else { return }

        // Map both ends of the drag into original-line space using the same band
        // bucketing as the rendered minimap image. When lines are already hidden
        // this maps within the current visible range, so the period can be
        // narrowed further.
        let lineA = originalIndex(forFraction: fromFraction, in: openTabs[index])
        let lineB = originalIndex(forFraction: toFraction, in: openTabs[index])
        let lower = min(lineA, lineB)
        let upper = max(lineA, lineB)
        guard lower <= upper else { return }

        // Capture the currently-selected real line BEFORE narrowing the range, so its
        // position is mapped against the current (pre-change) visible bounds.
        let previouslySelected = selectedOriginalIndex(in: openTabs[index])

        // Record the current range so a right-click can step back to it.
        pushVisibleBoundsHistory(for: index)
        openTabs[index].visibleLowerBound = lower
        openTabs[index].visibleUpperBound = upper

        // Keep the currently-selected line if it still falls within the new period;
        // otherwise make the first line of the period the selected line.
        let targetSelected: Int
        if let prev = previouslySelected, prev >= lower, prev <= upper {
            targetSelected = prev
        } else {
            targetSelected = lower
        }
        let selectionChanged = previouslySelected != targetSelected

        // Reposition the current-line indicator onto the (kept or first-line) selection.
        applyLineVisibilityChange(for: index, tabID: tabID, selectedOriginalIndex: targetSelected)

        // Scroll the top pane ONLY when the selected line actually changed (it became
        // the period's first line). When the selection is preserved, the top pane is
        // left alone — its own scroll-offset compensation keeps the content visually
        // stationary as the range narrows, so no scrolling is seen. The bottom pane
        // shows the start of the new subset. Deferred so the panes have rebuilt first.
        DispatchQueue.main.async { [weak self] in
            if selectionChanged {
                self?.syncSelectionFromFilteredIndex(targetSelected)
            }
            NotificationCenter.default.post(name: bottomPaneScrollToRowNotification, object: 0)
        }
    }

    /// Reveals any previously-hidden lines in the current tab.
    func showAllLines() {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard openTabs[index].isHidingLines else { return }
        // Preserve whichever real line is currently selected so its highlight lands
        // on the correct position once the full range is restored.
        let previouslySelected = selectedOriginalIndex(in: openTabs[index])
        openTabs[index].visibleLowerBound = nil
        openTabs[index].visibleUpperBound = nil
        // Fully revealing the log discards the tracked time-period history.
        openTabs[index].visibleBoundsHistory.removeAll()
        applyLineVisibilityChange(for: index, tabID: tabID, selectedOriginalIndex: previouslySelected)
        // Celebrate revealing the full log with a minimap colour-burst.
        minimapBurstTrigger &+= 1
    }

    /// Steps back to the previously-defined time period — one level of "zoom out".
    /// Each narrowing operation (minimap selection, Hide Lines Above/Below) records
    /// the prior visible range, so repeated right-clicks walk back through them.
    /// Once the full log is visible again the tracked history is cleared.
    func stepBackTimePeriod() {
        guard let tabID = selectedTabID,
              let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard !openTabs[index].visibleBoundsHistory.isEmpty else {
            // Nothing tracked: fall back to fully revealing the log if needed.
            if openTabs[index].isHidingLines { showAllLines() }
            return
        }
        // Keep the currently-selected real line so it stays in view after zoom-out.
        let previouslySelected = selectedOriginalIndex(in: openTabs[index])
        let previous = openTabs[index].visibleBoundsHistory.removeLast()
        openTabs[index].visibleLowerBound = previous.lower
        openTabs[index].visibleUpperBound = previous.upper
        // Returning to the full range clears any remaining history.
        if !openTabs[index].isHidingLines {
            openTabs[index].visibleBoundsHistory.removeAll()
        }
        applyLineVisibilityChange(for: index, tabID: tabID, selectedOriginalIndex: previouslySelected)
        // Scroll the panes so the previously-selected line stays visible as the
        // wider range is restored. Deferred so the panes have rebuilt first.
        if let selected = previouslySelected {
            DispatchQueue.main.async { [weak self] in
                self?.syncSelectionFromFilteredIndex(selected)
            }
        }
    }

    /// Pushes the tab's current visible range onto its history stack, so it can be
    /// restored later by `stepBackTimePeriod`.
    private func pushVisibleBoundsHistory(for index: Int) {
        openTabs[index].visibleBoundsHistory.append(
            VisibleRange(
                lower: openTabs[index].visibleLowerBound,
                upper: openTabs[index].visibleUpperBound
            )
        )
    }

    /// True when the current tab currently has hidden lines (drives the presence of
    /// the "Show All Lines" context-menu item).
    var isHidingLinesInCurrentTab: Bool {
        currentTab?.isHidingLines ?? false
    }

    private func applyLineVisibilityChange(for index: Int, tabID: UUID, selectedOriginalIndex: Int?) {
        // Bottom pane: re-clamp the displayed rows to the new visible range.
        updateDisplayedIndices(for: index)
        // Minimap & timeline: regenerate so their highlights cover only the
        // visible range of lines.
        generateMinimapData(for: tabID)
        generateTimelineData(for: tabID)
        // Reposition the current-line indicator: the minimap now spans a different
        // original-index range, so recompute the stored fraction for the same real
        // line (clamped into the new visible range) — otherwise the highlight would
        // stay at its old, now-incorrect position.
        if let original = selectedOriginalIndex {
            var target = original
            if let content = openTabs[index].content,
               let bounds = openTabs[index].visibleBounds(for: content.count) {
                target = min(max(target, bounds.lower), bounds.upper)
            }
            openTabs[index].selectedFraction = minimapFraction(forOriginalIndex: target, in: openTabs[index])
        }
        // Nudge SwiftUI so the top pane picks up the new lineProvider/lineCount.
        objectWillChange.send()
    }
}
