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
    func generateTimelineData(for tabID: UUID) {
        timelineTasks[tabID]?.cancel()
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, let i = self.openTabs.firstIndex(where: { $0.id == tabID }) else { return }
            self.openTabs[i].isGeneratingTimeline = true
        }

        let activeRules = highlightRules.filter { $0.isEnabled && $0.compiledRegex != nil }
        let isFiltered = !openTabs[index].filterPattern.isEmpty
        let filteredIndices = openTabs[index].filteredIndices
        let sortedMarks = Array(openTabs[index].markedIndices).sorted()
        let hasMarks = !sortedMarks.isEmpty

        let cache = openTabs[index].highlightMatches
        let activeRuleIDsCache = openTabs[index].activeRuleIDs
        let ruleColors = activeRules.map { $0.nsBackgroundColor.cgColor }
        let isDark = self.isSystemDark

        let filterValid = !isFiltered || !filteredIndices.isEmpty
        guard let content = openTabs[index].content,
              content.count > 0,
              !activeRules.isEmpty || hasMarks,
              filterValid || hasMarks,
              cache.count == activeRuleIDsCache.count else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let i = self.openTabs.firstIndex(where: { $0.id == tabID }) else { return }
                self.openTabs[i].timelineImage = nil
                self.openTabs[i].isGeneratingTimeline = false
            }
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

        timelineTasks[tabID] = Task.detached(priority: .utility) { [weak self] in
            guard let result = TimelineImageRenderer.render(input) else {
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                    self.openTabs[freshIndex].timelineImage = result.image
                    self.openTabs[freshIndex].timelineMatches = result.matches
                    self.openTabs[freshIndex].timelineActiveRuleIDs = result.activeRuleIDs
                    self.openTabs[freshIndex].isGeneratingTimeline = false
                    self.objectWillChange.send()
                }
            }
        }
    }

    func generateTimelineDataForAllTabs() {
        for tab in openTabs { generateTimelineData(for: tab.id) }
    }
}
