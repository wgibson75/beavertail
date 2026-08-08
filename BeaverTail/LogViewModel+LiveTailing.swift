import Foundation
import SwiftUI
import Combine
import AppKit

extension LogViewModel {
    // MARK: - Live Tailing

    func startLiveTailingForActiveTab() {
        stopLiveTailing()
        guard let tab = currentTab else { return }
        // The synthetic "Unique lines" tab has in-memory content and no backing file,
        // so there is nothing to tail — skip it (tailing a non-existent file would
        // otherwise flip it into a spurious "file deleted" error state).
        guard !tab.isUniqueLinesTab else { return }
        let fileURL = tab.fileURL
        let tabID = tab.id
        let hasInitialContent = tab.content != nil

        let tailTask = Task.detached(priority: .utility) { [weak self] in
            // The file-monitoring state machine (last-known size, remainder bytes,
            // presence) and all FileHandle/FileManager I/O live in the service; this
            // loop only reacts to the events it emits.
            let monitor = LiveTailFileMonitor(fileURL: fileURL, hasInitialContent: hasInitialContent)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { break }

                switch monitor.poll() {
                case .noChange:
                    continue

                case .fileDisappeared:
                    await MainActor.run { [weak self] in
                        self?.handleLiveTailFileDisappeared(tabID: tabID)
                    }

                case .reset:
                    // Re-read the file completely via the standard lazy load (which resets
                    // content on a background task properly) and bail this obsolete stream.
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        if let idx = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                            self.openTabs[idx].content = nil
                            self.triggerLazyLoadForTab(id: tabID)
                        }
                    }
                    return

                case .appended(let lines):
                    await MainActor.run { [weak self] in
                        self?.handleLiveTailAppend(lines, tabID: tabID)
                    }
                }
            }
        }
        liveTailTasks[tabID] = tailTask
    }

    /// Applies a "file deleted or moved" event to the tab: clears its content and
    /// derived state and surfaces the error status.
    func handleLiveTailFileDisappeared(tabID: UUID) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        openTabs[idx].content = nil
        openTabs[idx].filteredIndices = []
        openTabs[idx].highlightMatches = []
        openTabs[idx].markedIndices = []
        openTabs[idx].timelineMatches = []
        openTabs[idx].activeRuleIDs = []
        openTabs[idx].activeRuleSignatures = []
        openTabs[idx].timelineActiveRuleIDs = []
        openTabs[idx].statusLines = ["Unable to open file... File may have been deleted or moved."]
        fullyScannedRuleIDsByTab[tabID] = []
        updateDisplayedIndices(for: idx)
        generateMinimapData(for: tabID)
        generateTimelineData(for: tabID)
        objectWillChange.send()
    }

    /// Appends newly-tailed lines to the tab's content and updates the derived
    /// filter/highlight/summary state.
    func handleLiveTailAppend(_ finalLines: [String], tabID: UUID) {
        guard let idx = openTabs.firstIndex(where: { $0.id == tabID }),
              let content = openTabs[idx].content else { return }

        let baseOffset = content.count
        content.appendLines(finalLines)
        appendHighlightsForLiveTail(with: finalLines, startingAt: baseOffset)
        // Append to the filtered set BEFORE regenerating the summaries, so the
        // Timeline render sees this batch's newly-matched lines in the same pass
        // (headings then reflect new matches a batch sooner).
        appendFilterForLiveTail(with: finalLines, startingAt: baseOffset)
        // Coalesce minimap/timeline regeneration. Regenerating on every ~200ms batch
        // cancels the previous (utility-priority) render before it can finish, so under
        // high-rate tailing the panes never settle and the Timeline sticks on
        // "Processing highlight filters…". Throttle to a completed render at most
        // ~every 500ms (with a trailing pass).
        throttledRegenerateLiveTail(for: tabID)
        objectWillChange.send()
        if followTail {
            DispatchQueue.main.async {
                self.topPaneScrollEvents.send(.toBottom(force: false))
                // Note: we already send the bottom pane command in appendFilterForLiveTail.
            }
        }
    }

    func stopLiveTailing() {
        // Cancel all existing tail tasks
        for task in liveTailTasks.values {
            task.cancel()
        }
        liveTailTasks.removeAll()
    }

    /// Regenerates the minimap and Timeline for `tabID`, but at most once per
    /// `interval` while live-tailing, coalescing bursts. During high-rate tailing the
    /// raw appends arrive every ~200ms; regenerating on each one cancels the previous
    /// render before it finishes, so nothing ever settles and the Timeline is stuck
    /// showing "Processing highlight filters…". This runs the first regeneration
    /// immediately (leading edge) and, for any further appends inside the window,
    /// schedules exactly one trailing regeneration at the window's end — so a completed
    /// render lands promptly and the final state is always drawn once the burst ends.
    /// Low-rate tailing (batches further apart than `interval`) is unaffected: each
    /// batch regenerates immediately.
    func throttledRegenerateLiveTail(for tabID: UUID) {
        let interval: UInt64 = 500_000_000 // 500ms
        let now = DispatchTime.now()
        let last = lastLiveTailRegen[tabID] ?? DispatchTime(uptimeNanoseconds: 0)
        let elapsed = now.uptimeNanoseconds &- last.uptimeNanoseconds

        if elapsed >= interval {
            lastLiveTailRegen[tabID] = now
            generateMinimapData(for: tabID)
            generateTimelineData(for: tabID)
            return
        }

        // Inside the throttle window: ensure exactly one trailing regeneration fires
        // at the end of the window so the latest appended lines are rendered.
        guard !pendingLiveTailRegen.contains(tabID) else { return }
        pendingLiveTailRegen.insert(tabID)
        let remaining = interval &- elapsed
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(remaining))) { [weak self] in
            guard let self else { return }
            self.pendingLiveTailRegen.remove(tabID)
            // Skip if the tab has since closed.
            guard self.openTabs.contains(where: { $0.id == tabID }) else { return }
            self.lastLiveTailRegen[tabID] = DispatchTime.now()
            self.generateMinimapData(for: tabID)
            self.generateTimelineData(for: tabID)
            self.objectWillChange.send()
        }
    }

    func appearanceChanged(isDark: Bool) {
        if self.isSystemDark != isDark {
            self.isSystemDark = isDark
            generateTimelineDataForAllTabs()
        }
    }

    func appendFilterForLiveTail(with newLines: [String], startingAt originalStartIndex: Int) {
        guard !currentActiveFilterPattern.isEmpty,
              let tabID = selectedTabID,
              let tabIndex = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }

        let regexOptions: NSRegularExpression.Options = isCaseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: currentActiveFilterPattern, options: regexOptions) else { return }

        var incrementalMatches: [Int] = []
        for (offset, line) in newLines.enumerated() {
            let range = NSRange(location: 0, length: line.utf16.count)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                incrementalMatches.append(originalStartIndex + offset)
            }
        }

        if !incrementalMatches.isEmpty {
            openTabs[tabIndex].filteredIndices.append(contentsOf: incrementalMatches)
            updateDisplayedIndices(for: tabIndex)
            if followTail {
                DispatchQueue.main.async {
                    self.bottomPaneScrollEvents.send(.toBottom(force: false))
                }
            }
        }
    }

    func appendHighlightsForLiveTail(with newLines: [String], startingAt originalStartIndex: Int) {
        guard let tabID = selectedTabID,
              let tabIndex = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }

        let activeRules = activeHighlightRules
        guard !activeRules.isEmpty else { return }

        if openTabs[tabIndex].highlightMatches.isEmpty && openTabs[tabIndex].content?.count ?? 0 > 0 {
            openTabs[tabIndex].highlightMatches = [[Int]](repeating: [], count: activeRules.count)
            openTabs[tabIndex].activeRuleIDs = activeRules.map { $0.id }
        }

        guard openTabs[tabIndex].highlightMatches.count == activeRules.count else { return }

        var incrementalMatchesForRules = [[Int]](repeating: [], count: activeRules.count)

        for (idx, rule) in activeRules.enumerated() {
            guard let regex = rule.compiledRegex else { continue }
            for (offset, line) in newLines.enumerated() {
                let range = NSRange(location: 0, length: line.utf16.count)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    incrementalMatchesForRules[idx].append(originalStartIndex + offset)
                }
            }
        }

        for idx in 0..<activeRules.count {
            if !incrementalMatchesForRules[idx].isEmpty {
                openTabs[tabIndex].highlightMatches[idx].append(contentsOf: incrementalMatchesForRules[idx])
            }
        }
    }
}
