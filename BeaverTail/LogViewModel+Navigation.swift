//
//  LogViewModel+Navigation.swift
//  BeaverTail
//

import AppKit
import Foundation
import SwiftUI

extension LogViewModel {

    // MARK: - Hidden-line-aware coordinate mapping
    //
    // The minimap and timeline images span only the currently-visible
    // original-index range [visibleLower, visibleUpper]. `selectedFraction` is a
    // 0...1 fraction of that image, and the top pane's row indices are relative to
    // the first visible line (its provider is a `RangeLineProvider` when lines are
    // hidden). When lines are hidden above the selection an original line index
    // must therefore be shifted by the visible lower bound before it can be used
    // as a minimap fraction or a top-pane row — otherwise a click on a coloured
    // highlight jumps to the wrong line.

    /// Inclusive original index of the first currently-visible line in `tab`.
    private func visibleLowerBound(of tab: LogTab) -> Int {
        tab.visibleBounds(for: tab.content?.count ?? 0)?.lower ?? 0
    }

    /// Converts an original line index to the row used by the top pane's provider
    /// (identity unless lines are hidden above the selection).
    private func topPaneRow(forOriginalIndex originalIndex: Int, in tab: LogTab) -> Int {
        originalIndex - visibleLowerBound(of: tab)
    }

    /// Converts an original line index to a 0...1 fraction of the minimap/timeline
    /// image, which spans only the currently-visible original-index range.
    ///
    /// Visible line `r` of `N` visible lines maps to `r / (N - 1)`, so the endpoints
    /// are exact: the first visible line sits at the very top (`0`) and the last at
    /// the very bottom (`1`), with interior lines spread linearly between. Each
    /// fraction still falls inside the line's drawn highlight band, so the
    /// current-position indicator stays on the highlight at every scale — including
    /// logs with only a handful of lines, where each band is many pixels tall. For
    /// large logs a band is sub-pixel, so this is indistinguishable from the exact
    /// drawn pixel.
    func minimapFraction(forOriginalIndex originalIndex: Int, in tab: LogTab) -> CGFloat {
        let span = tab.lineCount
        guard span > 1 else { return 0 }
        let relative = max(0, min(span - 1, originalIndex - visibleLowerBound(of: tab)))
        return max(0, min(1, CGFloat(relative) / CGFloat(span - 1)))
    }

    /// Converts a 0...1 minimap/timeline click fraction to an original line index,
    /// using the SAME `visibleCount`-band bucketing as the rendered image so a click
    /// on a coloured highlight resolves to exactly the line that band represents.
    /// The result is clamped to the visible range.
    func originalIndex(forFraction fraction: CGFloat, in tab: LogTab) -> Int {
        let span = tab.lineCount
        let lower = visibleLowerBound(of: tab)
        guard span > 0 else { return lower }
        let clamped = max(0, min(1, fraction))
        let offset = min(span - 1, Int(clamped * CGFloat(span)))
        return lower + offset
    }

    /// Inverse of `minimapFraction`: maps the tab's stored `selectedFraction` back to
    /// an original line index using the tab's *current* visible range. Returns `nil`
    /// when nothing is currently selected.
    func selectedOriginalIndex(in tab: LogTab) -> Int? {
        guard let fraction = selectedFractionByTab[tab.id] else { return nil }
        let span = tab.lineCount
        guard span > 0 else { return nil }
        guard span > 1 else { return visibleLowerBound(of: tab) }
        // Inverse of the `r / (N - 1)` indicator mapping.
        let offset = min(span - 1, max(0, Int((fraction * CGFloat(span - 1)).rounded())))
        return visibleLowerBound(of: tab) + offset
    }

    /// Steps the selection to the next match of the given highlight rule, wrapping
    /// to the first match after the last. Driven by left-clicking a timeline heading.
    func jumpToNextMatch(forRuleID ruleID: UUID) {
        jumpToAdjacentMatch(forRuleID: ruleID, backwards: false)
    }

    /// Steps the selection to the previous match of the given highlight rule,
    /// wrapping to the last match when there are none before the current position.
    /// Driven by right-clicking a timeline heading (the reverse of a left-click).
    func jumpToPreviousMatch(forRuleID ruleID: UUID) {
        jumpToAdjacentMatch(forRuleID: ruleID, backwards: true)
    }

    /// Shared forward/backward timeline-heading navigation. Advances from the last
    /// line the timeline jumped to (shared across headings) to this rule's adjacent
    /// occurrence in the requested direction, wrapping only when there is nothing
    /// further on in that direction.
    private func jumpToAdjacentMatch(forRuleID ruleID: UUID, backwards: Bool) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = openTabs[index]
        guard tab.lineCount > 0, tab.content != nil else { return }

        // Locate the column this rule occupies in the timeline, then the matching
        // per-column match list (offset by one when a marks column is present).
        guard let column = tab.timelineActiveRuleIDs.firstIndex(of: ruleID) else { return }
        let hasMarks = !tab.markedIndices.isEmpty
        let matchIndex = hasMarks ? column + 1 : column
        let allMatches = tab.timelineMatches
        guard matchIndex >= 0, matchIndex < allMatches.count else { return }
        let ruleMatches = allMatches[matchIndex]
        guard !ruleMatches.isEmpty else { return }

        // Continue from the current position in the log: pick this rule's adjacent
        // occurrence in the requested direction (forward = strictly after, backward =
        // strictly before the last jumped-to line), wrapping around only when there
        // is nothing further on in that direction. This keeps navigation continuous
        // even when switching between headings.
        let current = timelineCurrentLineByTab[tabID]
        let targetLine: Int
        if let current {
            // First index whose value is > current (forward) / >= current (backward).
            var left = 0
            var right = ruleMatches.count
            while left < right {
                let mid = left + (right - left) / 2
                let goRight = backwards ? ruleMatches[mid] < current : ruleMatches[mid] <= current
                if goRight { left = mid + 1 } else { right = mid }
            }
            if backwards {
                // Last occurrence before `current`; wrap to the final match.
                targetLine = left - 1 >= 0 ? ruleMatches[left - 1] : ruleMatches[ruleMatches.count - 1]
            } else {
                // First occurrence after `current`; wrap to the first match.
                targetLine = left < ruleMatches.count ? ruleMatches[left] : ruleMatches[0]
            }
        } else {
            targetLine = backwards ? ruleMatches[ruleMatches.count - 1] : ruleMatches[0]
        }
        timelineCurrentLineByTab[tabID] = targetLine

        // Mark this rule's column as the selected one so the current-position
        // indicator spans only that column.
        timelineSelectedRuleID = ruleID
        timelineSelectionIsMarks = false

        isScrubbingMinimap = false
        selectedFractionByTab[tabID] = minimapFraction(forOriginalIndex: targetLine, in: openTabs[index])
        // Heading navigation must never trigger the top pane's horizontal
        // auto-scroll — even when the heading has a single entry and repeated
        // clicks re-target the already-selected row. Post an explicit request with
        // allowsHorizontalScroll:false so the handler's "repeated click" heuristic
        // (selectedRow == row) can't misfire. Horizontal scrolling is reserved for
        // clicking a highlight entry (log line) twice.
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: TopPaneDirectScrollRequest(
                lineIndex: topPaneRow(forOriginalIndex: targetLine, in: openTabs[index]),
                allowsHorizontalScroll: false
            )
        )
        triggerMinimapShimmer()
        triggerTimelineJump()
    }

    func jumpFromTimeline(fraction: CGFloat, ruleIndex: Int) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }
        let totalCount = openTabs[index].lineCount
        guard totalCount > 0 else {
            return
        }
        guard openTabs[index].content != nil else {
            return
        }

        // The timeline image spans only the visible range, so map the click
        // fraction into original-line space using the image's band bucketing.
        let exactLine = originalIndex(forFraction: fraction, in: openTabs[index])

        let hasMarks = !openTabs[index].markedIndices.isEmpty
        let mappedRuleIndex = ruleIndex == -1 ? 0 : (hasMarks ? ruleIndex + 1 : ruleIndex)

        // Mark which column this click belongs to so the current-position
        // indicator spans only that column (marks column, or a specific rule).
        let displayedRuleIDs = openTabs[index].timelineActiveRuleIDs
        if ruleIndex == -1 {
            timelineSelectionIsMarks = true
            timelineSelectedRuleID = nil
        } else {
            timelineSelectionIsMarks = false
            timelineSelectedRuleID = ruleIndex >= 0 && ruleIndex < displayedRuleIDs.count
                ? displayedRuleIDs[ruleIndex] : nil
        }

        let cachedMatches = openTabs[index].timelineMatches
        guard mappedRuleIndex >= 0, mappedRuleIndex < cachedMatches.count, !cachedMatches[mappedRuleIndex].isEmpty else {
            selectedFractionByTab[tabID] = minimapFraction(forOriginalIndex: exactLine, in: openTabs[index])
            // Horizontal auto-scroll of long lines is only allowed on a repeated
            // click of the same entry AND when the bottom-pane scroll option is on.
            let isRepeatedTimelineClick = timelineCurrentLineByTab[tabID] == exactLine
            // Record the current position so a subsequent heading click continues
            // forward from here.
            timelineCurrentLineByTab[tabID] = exactLine
            NotificationCenter.default.post(
                name: topPaneDirectScrollNotification,
                object: TopPaneDirectScrollRequest(
                    lineIndex: topPaneRow(forOriginalIndex: exactLine, in: openTabs[index]),
                    allowsHorizontalScroll: isRepeatedTimelineClick && bottomPaneHorizontalScroll
                )
            )
            triggerTimelineJump()
            return
        }

        let ruleMatches = cachedMatches[mappedRuleIndex]
        var closestVal = ruleMatches[0]
        var minDiff = abs(ruleMatches[0] - exactLine)

        var left = 0
        var right = ruleMatches.count
        while left < right {
            let mid = left + (right - left) / 2
            if ruleMatches[mid] < exactLine { left = mid + 1 } else { right = mid }
        }

        if left < ruleMatches.count {
            let diff = abs(ruleMatches[left] - exactLine)
            if diff < minDiff {
                minDiff = diff
                closestVal = ruleMatches[left]
            }
        }
        if left - 1 >= 0 {
            let diff = abs(ruleMatches[left - 1] - exactLine)
            if diff < minDiff {
                closestVal = ruleMatches[left - 1]
            }
        }

        // We set scrubbing minimap to false because we want it to snap
        isScrubbingMinimap = false
        selectedFractionByTab[tabID] = minimapFraction(forOriginalIndex: closestVal, in: openTabs[index])
        // Horizontal auto-scroll of long lines is only allowed on a repeated click
        // of the same entry AND when the bottom-pane scroll option is enabled.
        let isRepeatedTimelineClick = timelineCurrentLineByTab[tabID] == closestVal
        // Record the current position so a subsequent heading click continues
        // forward from here.
        timelineCurrentLineByTab[tabID] = closestVal
        // Publish the scroll offset immediately.
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: TopPaneDirectScrollRequest(
                lineIndex: topPaneRow(forOriginalIndex: closestVal, in: openTabs[index]),
                allowsHorizontalScroll: isRepeatedTimelineClick && bottomPaneHorizontalScroll
            )
        )
        triggerTimelineJump()
    }

    func syncSelectionFromFilteredIndex(_ originalIndex: Int, allowsHorizontalScroll: Bool = false) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[index].lineCount
        guard totalCount > 0 else { return }
        selectedFractionByTab[tabID] = minimapFraction(forOriginalIndex: originalIndex, in: openTabs[index])
        // Post an explicit request carrying the caller's horizontal-scroll intent.
        // Programmatic "jump to a new line" callers (time-period selection, zoom
        // step-back, single bottom-pane clicks, mark navigation) pass `false`, so the
        // top pane only scrolls vertically to reveal the line. Only an intentional
        // repeated bottom-pane click passes `true`. Sending a bare Int previously left
        // the handler's `explicitHorizontalScroll` nil, letting it fall back to a
        // `selectedRow == row` heuristic that misfired (the row is frequently already
        // selected by a preceding visibility change) and made the top pane scroll
        // horizontally by mistake.
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: TopPaneDirectScrollRequest(
                lineIndex: topPaneRow(forOriginalIndex: originalIndex, in: openTabs[index]),
                allowsHorizontalScroll: allowsHorizontalScroll
            )
        )
        // Flash the current-position indicator so the new position stands out. Covers
        // bottom-pane filtered-line clicks, mark-block navigation and zoom step-back,
        // all of which route through here.
        triggerMinimapShimmer()
    }

    func jumpFromMinimap(fraction: CGFloat) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[index].lineCount
        guard totalCount > 0 else { return }
        let clampedFraction = max(0, min(1, fraction))

        // The minimap image spans only the currently-visible original-index range
        // [rangeStart, rangeEnd). Map the click fraction into ORIGINAL-line space so
        // it is comparable with the highlight-match caches (which are stored as
        // original indices) — otherwise, when lines are hidden above the selection,
        // a click on a coloured highlight snaps to the wrong line. The mapping uses
        // the same band bucketing as the rendered image so the clicked highlight
        // resolves to exactly the line that band represents.
        let rangeStart = visibleLowerBound(of: openTabs[index])
        let rangeEndInclusive = rangeStart + totalCount - 1
        let exactLine = originalIndex(forFraction: clampedFraction, in: openTabs[index])
        var finalExactLine = exactLine

        let cache = openTabs[index].highlightMatches
        var globalClosestVal = -1
        var globalMinDiff = Int.max
        // Track which rule (index into `cache` / `activeRuleIDs`) the closest match
        // belongs to, so a snapped click can also select that rule's Timeline column.
        var globalClosestRuleIndex = -1

        // Only consider matches inside the visible range — the minimap never draws
        // highlights for hidden lines, so we must never snap to one.
        for (ruleIndex, matches) in cache.enumerated() where !matches.isEmpty {
            var left = 0
            var right = matches.count
            while left < right {
                let mid = left + (right - left) / 2
                if matches[mid] < exactLine { left = mid + 1 } else { right = mid }
            }
            for candidateIndex in [left, left - 1] where candidateIndex >= 0 && candidateIndex < matches.count {
                let candidate = matches[candidateIndex]
                guard candidate >= rangeStart, candidate <= rangeEndInclusive else { continue }
                let diff = abs(candidate - exactLine)
                if diff < globalMinDiff {
                    globalMinDiff = diff
                    globalClosestVal = candidate
                    globalClosestRuleIndex = ruleIndex
                }
            }
        }

        // The rule whose match we snapped to (if any), used for Timeline selection.
        var snappedRuleIndex = -1
        if globalClosestVal != -1 {
            // Snap if within roughly 3 pixels in the minimap representation
            let stickyTolerance = max(1, totalCount / 1500) * 3
            if globalMinDiff <= stickyTolerance {
                finalExactLine = globalClosestVal
                snappedRuleIndex = globalClosestRuleIndex
            }
        }

        // A one-pixel movement in the minimap can represent many log lines in
        // large files, so treat the second click as repeated if it lands in the
        // same approximate minimap bucket rather than requiring the exact same
        // line number.
        let repeatedSelectionTolerance = max(1, totalCount / 1500)
        let isRepeatedMinimapSelection = lastMinimapSelectedLineByTab[tabID].map {
            abs($0 - finalExactLine) <= repeatedSelectionTolerance
        } ?? false
        lastMinimapSelectedLineByTab[tabID] = finalExactLine
        isScrubbingMinimap = false
        selectedFractionByTab[tabID] = minimapFraction(forOriginalIndex: finalExactLine, in: openTabs[index])
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: TopPaneDirectScrollRequest(
                lineIndex: topPaneRow(forOriginalIndex: finalExactLine, in: openTabs[index]),
                // Only auto-scroll long lines horizontally when a repeated minimap
                // selection coincides with the bottom-pane scroll option being on.
                allowsHorizontalScroll: isRepeatedMinimapSelection && bottomPaneHorizontalScroll
            )
        )
        // If the jumped-to line is also present in the bottom pane's filtered set,
        // scroll the bottom pane to it (vertically centred) and record it as the
        // bottom pane's selected line so the highlight tracks the minimap jump.
        if let bottomRow = bottomPaneRow(forOriginalIndex: finalExactLine) {
            bottomPaneSelectedOriginal[tabID] = finalExactLine
            NotificationCenter.default.post(
                name: bottomPaneScrollToRowCenteredNotification,
                object: bottomRow
            )
        }
        // If the snapped line belongs to a rule that also has a Timeline column,
        // select and highlight that column's entry (mirroring a heading click) and
        // scroll the Timeline to it.
        if snappedRuleIndex >= 0, snappedRuleIndex < openTabs[index].activeRuleIDs.count {
            let ruleID = openTabs[index].activeRuleIDs[snappedRuleIndex]
            if openTabs[index].timelineActiveRuleIDs.contains(ruleID) {
                timelineSelectedRuleID = ruleID
                timelineSelectionIsMarks = false
                timelineCurrentLineByTab[tabID] = finalExactLine
                triggerTimelineJump()
            }
        }
        // Flash the current-position indicator so the jumped-to line stands out.
        triggerMinimapShimmer()
    }

    func jumpToFraction(_ fraction: CGFloat) {
        guard let tabID = selectedTabID, openTabs.contains(where: { $0.id == tabID }) else { return }
        isScrubbingMinimap = true
        selectedFractionByTab[tabID] = max(0, min(1, fraction))
    }

    func updateMinimapFromLineIndex(_ index: Int) {
        guard let tabID = selectedTabID, let tabIdx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[tabIdx].lineCount
        guard totalCount > 0 else { return }
        // `index` is an ORIGINAL line index (from `provider.originalIndex(at:)`);
        // convert it into the minimap image's visible-range fraction.
        selectedFractionByTab[tabID] = minimapFraction(forOriginalIndex: index, in: openTabs[tabIdx])
        // Flash the current-position indicator so a top-pane line click is reflected
        // by the minimap's glow/shimmer at the new position.
        triggerMinimapShimmer()
    }
}
