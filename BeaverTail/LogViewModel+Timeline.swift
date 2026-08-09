//
//  LogViewModel+Timeline.swift
//  BeaverTail
//
//  Timeline (per-rule density strip) image generation, split out of LogViewModel
//  to keep that file under the SwiftLint file-length limit.
//

import AppKit
import Combine
import Foundation

extension LogViewModel {
    /// Coalescing front door for Timeline rendering. At most one render runs per tab
    /// at a time; if a render is requested while one is in flight, exactly one more
    /// render is scheduled (using the latest state) for when the current finishes.
    ///
    /// Routing every caller through here — the progressive filter scan, the
    /// progressive highlight scan, visibility/theme changes, etc. — means they no
    /// longer cancel each other's in-flight render. Previously overlapping callers
    /// could repeatedly cancel a render before it completed, so nothing appeared until
    /// the whole scan finished; now the latest state is always drawn promptly.
    func generateTimelineData(for tabID: UUID) {
        if isGeneratingTimelineByTab[tabID] == true {
            pendingTimelineRender[tabID] = true
            return
        }
        isGeneratingTimelineByTab[tabID] = true
        renderTimeline(for: tabID)
    }

    /// Clears the in-flight flag and, if another render was requested while this one
    /// ran, kicks exactly one more so the freshest state is drawn. Always called on
    /// the main actor at the end of a (non-cancelled) render.
    private func finishTimelineRender(for tabID: UUID) {
        isGeneratingTimelineByTab[tabID] = false
        if pendingTimelineRender[tabID] == true {
            pendingTimelineRender[tabID] = false
            generateTimelineData(for: tabID)
        }
    }

    /// The actual render worker. Only ever entered with the in-flight flag already set
    /// (by `generateTimelineData`), so it never has to cancel a previous render.
    private func renderTimeline(for tabID: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else {
            finishTimelineRender(for: tabID)
            return
        }

        let activeRules = activeHighlightRules
        let isFiltered = !openTabs[index].filterPattern.isEmpty
        let filteredIndices = openTabs[index].filteredIndices
        let sortedMarks = Array(openTabs[index].markedIndices).sorted()
        let hasMarks = !sortedMarks.isEmpty

        let cache = openTabs[index].highlightMatches
        let activeRuleIDsCache = openTabs[index].activeRuleIDs
        let ruleColors = activeRules.map { $0.nsBackgroundColor.cgColor }
        let isDark = self.isSystemDark

        let filterValid = !isFiltered || !filteredIndices.isEmpty
        // The Timeline View only shows entries that match the supplied regex Filter.
        // With no filter entered (or a filter that matched no lines) there is nothing
        // to show, so clear any existing timeline and bail — the view then displays
        // an appropriate message instead.
        guard let content = openTabs[index].content,
              content.count > 0,
              isFiltered,
              !activeRules.isEmpty || hasMarks,
              filterValid || hasMarks,
              cache.count == activeRuleIDsCache.count else {
            self.timelineImageByTab[tabID] = nil
            self.openTabs[index].timelineMatches = []
            self.openTabs[index].timelineActiveRuleIDs = []
            finishTimelineRender(for: tabID)
            return
        }

        // Map active rules to the cached indices.
        let mappedCacheIndices = activeRules.compactMap { rule -> Int? in
            activeRuleIDsCache.firstIndex(of: rule.id)
        }

        let logTotalLines = content.count
        // Restrict the timeline to the visible range when lines are hidden.
        let vBounds = openTabs[index].visibleBounds(for: logTotalLines)
        let rangeStart = vBounds?.lower ?? 0
        let rangeEnd = vBounds.map { $0.upper + 1 } ?? logTotalLines

        // Package the inputs and hand the heavy Core Graphics work to the
        // renderer service; the view model only applies the finished result.
        let input = TimelineRenderInput(
            ruleColors: ruleColors,
            activeRuleIDs: activeRules.map { $0.id },
            mappedCacheIndices: mappedCacheIndices,
            cache: cache,
            isFiltered: isFiltered,
            filteredIndices: filteredIndices,
            sortedMarks: sortedMarks,
            hasMarks: hasMarks,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            isDark: isDark
        )

        // Run the render at `.userInitiated` so it isn't starved by the filter and
        // highlight scans, which saturate the performance cores (also `.userInitiated`)
        // via `concurrentPerform`. A `.utility` render is parked on the efficiency
        // cores and effectively makes no progress until those scans finish — which is
        // why progressive entries never appeared mid-scan. The coalescing scheduler
        // guarantees only one render runs at a time, and each is cheap (O(filteredCount
        // + matches)), so the CPU it borrows from the scans is small.
        timelineTasks[tabID] = Task.detached(priority: .userInitiated) { [weak self] in
            let result = TimelineImageRenderer.render(input)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if Task.isCancelled {
                    // The render was superseded/cancelled (e.g. the tab was closed or
                    // switched away from). Clear the in-flight flag and drop any pending
                    // re-render; the tab re-renders from scratch when next shown.
                    self.isGeneratingTimelineByTab[tabID] = false
                    self.pendingTimelineRender[tabID] = false
                    return
                }
                if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                    if let result {
                        self.timelineImageByTab[tabID] = result.image
                        self.openTabs[freshIndex].timelineMatches = result.matches
                        self.openTabs[freshIndex].timelineActiveRuleIDs = result.activeRuleIDs
                    } else {
                        // Nothing matched the filter — clear so the view shows the
                        // "No Highlight Rules matched" message instead of a blank pane.
                        self.timelineImageByTab[tabID] = nil
                        self.openTabs[freshIndex].timelineMatches = []
                        self.openTabs[freshIndex].timelineActiveRuleIDs = []
                    }
                    self.objectWillChange.send()
                }
                self.finishTimelineRender(for: tabID)
            }
        }
    }

    func generateTimelineDataForAllTabs() {
        for tab in openTabs { generateTimelineData(for: tab.id) }
    }
}
