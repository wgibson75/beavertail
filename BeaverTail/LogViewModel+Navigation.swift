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
    /// This returns the centre of the exact pixel the minimap image draws the line
    /// into. The image places visible line `r` in bucket `ceil((r+1)·H/N) - 1`
    /// (where `H` is the image height and `N` the visible count — see
    /// `generateMinimapData`), which sits at the bottom edge of the line's band, not
    /// its middle. Matching that bucket keeps the hover indicator exactly on the
    /// highlight even when only a handful of lines are visible; for large logs it is
    /// identical to the drawn pixel and so remains correct there too.
    func minimapFraction(forOriginalIndex originalIndex: Int, in tab: LogTab) -> CGFloat {
        let span = tab.lineCount
        guard span > 0 else { return 0 }
        let relative = max(0, min(span - 1, originalIndex - visibleLowerBound(of: tab)))
        let height = minimapImageHeight
        let bucket = min(height - 1,
                         Int(ceil(Double(relative + 1) * Double(height) / Double(span))) - 1)
        return max(0, min(1, (CGFloat(bucket) + 0.5) / CGFloat(height)))
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
        guard let fraction = tab.selectedFraction else { return nil }
        let span = tab.lineCount
        guard span > 0 else { return nil }
        // Inverse of the centred `(r + 0.5)/N` mapping: floor(fraction * N).
        let offset = min(span - 1, max(0, Int(fraction * CGFloat(span))))
        return visibleLowerBound(of: tab) + offset
    }

    /// Steps the selection to the next match of the given highlight rule, wrapping
    /// to the first match after the last. Driven by clicking a timeline heading.
    func jumpToNextMatch(forRuleID ruleID: UUID) {
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

        // Continue from the current position in the log: pick this rule's first
        // occurrence strictly after the last line the timeline jumped to, wrapping
        // to its first occurrence only when there are none further on. This keeps
        // navigation moving forward through the log even when switching between
        // headings, and never jumps backward while forward entries remain.
        let current = timelineCurrentLineByTab[tabID]
        let targetLine: Int
        if let current {
            var left = 0
            var right = ruleMatches.count
            while left < right {
                let mid = left + (right - left) / 2
                if ruleMatches[mid] <= current { left = mid + 1 } else { right = mid }
            }
            targetLine = left < ruleMatches.count ? ruleMatches[left] : ruleMatches[0]
        } else {
            targetLine = ruleMatches[0]
        }
        timelineCurrentLineByTab[tabID] = targetLine

        // Mark this rule's column as the selected one so the current-position
        // indicator spans only that column.
        timelineSelectedRuleID = ruleID
        timelineSelectionIsMarks = false

        isScrubbingMinimap = false
        openTabs[index].selectedFraction = minimapFraction(forOriginalIndex: targetLine, in: openTabs[index])
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: topPaneRow(forOriginalIndex: targetLine, in: openTabs[index])
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
            openTabs[index].selectedFraction = minimapFraction(forOriginalIndex: exactLine, in: openTabs[index])
            // Record the current position so a subsequent heading click continues
            // forward from here.
            timelineCurrentLineByTab[tabID] = exactLine
            NotificationCenter.default.post(
                name: topPaneDirectScrollNotification,
                object: topPaneRow(forOriginalIndex: exactLine, in: openTabs[index])
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
        openTabs[index].selectedFraction = minimapFraction(forOriginalIndex: closestVal, in: openTabs[index])
        // Record the current position so a subsequent heading click continues
        // forward from here.
        timelineCurrentLineByTab[tabID] = closestVal
        // Publish the scroll offset immediately.
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: topPaneRow(forOriginalIndex: closestVal, in: openTabs[index])
        )
        triggerTimelineJump()
    }

    func syncSelectionFromFilteredIndex(_ originalIndex: Int) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[index].lineCount
        guard totalCount > 0 else { return }
        openTabs[index].selectedFraction = minimapFraction(forOriginalIndex: originalIndex, in: openTabs[index])
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: topPaneRow(forOriginalIndex: originalIndex, in: openTabs[index])
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

        // Only consider matches inside the visible range — the minimap never draws
        // highlights for hidden lines, so we must never snap to one.
        let consider: (Int) -> Void = { candidate in
            guard candidate >= rangeStart, candidate <= rangeEndInclusive else { return }
            let diff = abs(candidate - exactLine)
            if diff < globalMinDiff {
                globalMinDiff = diff
                globalClosestVal = candidate
            }
        }

        for matches in cache {
            if !matches.isEmpty {
                var left = 0
                var right = matches.count
                while left < right {
                    let mid = left + (right - left) / 2
                    if matches[mid] < exactLine { left = mid + 1 } else { right = mid }
                }

                if left < matches.count { consider(matches[left]) }
                if left - 1 >= 0 { consider(matches[left - 1]) }
            }
        }

        if globalClosestVal != -1 {
            // Snap if within roughly 3 pixels in the minimap representation
            let stickyTolerance = max(1, totalCount / 1500) * 3
            if globalMinDiff <= stickyTolerance {
                finalExactLine = globalClosestVal
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
        openTabs[index].selectedFraction = minimapFraction(forOriginalIndex: finalExactLine, in: openTabs[index])
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: TopPaneDirectScrollRequest(
                lineIndex: topPaneRow(forOriginalIndex: finalExactLine, in: openTabs[index]),
                allowsHorizontalScroll: isRepeatedMinimapSelection
            )
        )
        // Flash the current-position indicator so the jumped-to line stands out.
        triggerMinimapShimmer()
    }

    func jumpToFraction(_ fraction: CGFloat) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        isScrubbingMinimap = true
        openTabs[index].selectedFraction = max(0, min(1, fraction))
    }

    func updateMinimapFromLineIndex(_ index: Int) {
        guard let tabID = selectedTabID, let tabIdx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[tabIdx].lineCount
        guard totalCount > 0 else { return }
        // `index` is an ORIGINAL line index (from `provider.originalIndex(at:)`);
        // convert it into the minimap image's visible-range fraction.
        openTabs[tabIdx].selectedFraction = minimapFraction(forOriginalIndex: index, in: openTabs[tabIdx])
        // Flash the current-position indicator so a top-pane line click is reflected
        // by the minimap's glow/shimmer at the new position.
        triggerMinimapShimmer()
    }
}
