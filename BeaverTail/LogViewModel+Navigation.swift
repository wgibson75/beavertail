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
    func minimapFraction(forOriginalIndex originalIndex: Int, in tab: LogTab) -> CGFloat {
        let span = tab.lineCount
        guard span > 1 else { return 0 }
        return max(0, min(1, CGFloat(originalIndex - visibleLowerBound(of: tab)) / CGFloat(span - 1)))
    }

    /// Inverse of `minimapFraction`: maps the tab's stored `selectedFraction` back to
    /// an original line index using the tab's *current* visible range. Returns `nil`
    /// when nothing is currently selected.
    func selectedOriginalIndex(in tab: LogTab) -> Int? {
        guard let fraction = tab.selectedFraction else { return nil }
        let span = tab.lineCount
        guard span > 0 else { return nil }
        let offset = Int((fraction * CGFloat(span - 1)).rounded())
        return visibleLowerBound(of: tab) + offset
    }

    func jumpFromTimeline(fraction: CGFloat, ruleIndex: Int) {
        guard let tabID = selectedTabID, let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let totalCount = openTabs[index].lineCount
        guard totalCount > 0 else { return }
        guard openTabs[index].content != nil else { return }

        // The timeline image spans only the visible range, so map the click
        // fraction into original-line space starting at the visible lower bound.
        let rangeStart = visibleLowerBound(of: openTabs[index])
        let exactLine = rangeStart + Int(fraction * CGFloat(totalCount - 1))

        let hasMarks = !openTabs[index].markedIndices.isEmpty
        let mappedRuleIndex = ruleIndex == -1 ? 0 : (hasMarks ? ruleIndex + 1 : ruleIndex)

        let cachedMatches = openTabs[index].timelineMatches
        guard mappedRuleIndex >= 0, mappedRuleIndex < cachedMatches.count, !cachedMatches[mappedRuleIndex].isEmpty else {
            openTabs[index].selectedFraction = minimapFraction(forOriginalIndex: exactLine, in: openTabs[index])
            NotificationCenter.default.post(
                name: topPaneDirectScrollNotification,
                object: topPaneRow(forOriginalIndex: exactLine, in: openTabs[index])
            )
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
        // Publish the scroll offset immediately.
        NotificationCenter.default.post(
            name: topPaneDirectScrollNotification,
            object: topPaneRow(forOriginalIndex: closestVal, in: openTabs[index])
        )
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
        // a click on a coloured highlight snaps to the wrong line.
        let rangeStart = visibleLowerBound(of: openTabs[index])
        let rangeEndInclusive = rangeStart + totalCount - 1
        let exactLine = rangeStart + Int(clampedFraction * CGFloat(totalCount - 1))
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
    }
}
