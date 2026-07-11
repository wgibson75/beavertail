import Foundation
import SwiftUI
import Combine
import AppKit

extension LogViewModel {
    // MARK: - Live Tailing

    func startLiveTailingForActiveTab() {
        stopLiveTailing()
        guard let tab = currentTab else { return }
        let fileURL = tab.fileURL
        let tabID = tab.id

        let tailTask = Task.detached(priority: .utility) { [weak self] in
            var lastKnownSize: UInt64 = 0
            var wasFilePresent = true
            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                lastKnownSize = (attributes[.size] as? UInt64) ?? 0
            } else {
                wasFilePresent = tab.content != nil
            }
            var remainderData = Data()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { break }

                guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let currentSize = attributes[.size] as? UInt64 else {
                    // File may be deleted or moved.
                    if wasFilePresent {
                        wasFilePresent = false
                        lastKnownSize = 0
                        remainderData = Data()
                        await MainActor.run { [weak self] in
                            guard let self = self else { return }
                            if let idx = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                                self.openTabs[idx].content = nil
                                self.openTabs[idx].filteredIndices = []
                                self.openTabs[idx].highlightMatches = []
                                self.openTabs[idx].markedIndices = []
                                self.openTabs[idx].timelineMatches = []
                                self.openTabs[idx].activeRuleIDs = []
                                self.openTabs[idx].activeRuleSignatures = []
                                self.openTabs[idx].timelineActiveRuleIDs = []
                                self.openTabs[idx].statusLines = ["Unable to open file... File may have been deleted or moved."]
                                self.fullyScannedRuleIDsByTab[tabID] = []
                                self.updateDisplayedIndices(for: idx)
                                self.generateMinimapData(for: tabID)
                                self.generateTimelineData(for: tabID)
                                self.objectWillChange.send()
                            }
                        }
                    }
                    continue
                }

                if currentSize < lastKnownSize || !wasFilePresent {
                    // Log rotated or truncated, OR log file re-created/written to after being deleted.
                    lastKnownSize = 0
                    remainderData = Data()
                    
                    // We need to re-read the file completely. To avoid blocking the tailing thread long,
                    // we can trigger the standard lazy load (which resets content on a background task properly)
                    // and bail this obsolete live tail stream.
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        if let idx = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                            self.openTabs[idx].content = nil
                            self.triggerLazyLoadForTab(id: tabID)
                        }
                    }
                    return
                }

                if currentSize > lastKnownSize {
                    guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { continue }
                    do {
                        try fileHandle.seek(toOffset: lastKnownSize)
                        let bytesToRead = currentSize - lastKnownSize
                        let readCount = min(bytesToRead, 50 * 1024 * 1024)
                        if let newData = try fileHandle.read(upToCount: Int(readCount)), !newData.isEmpty {
                            lastKnownSize += UInt64(newData.count)

                            var dataToProcess = remainderData
                            dataToProcess.append(newData)

                            if let lastNewline = dataToProcess.lastIndex(of: 0x0A) {
                                let completeData = dataToProcess.prefix(upTo: lastNewline + 1)
                                remainderData = Data(dataToProcess.suffix(from: lastNewline + 1))

                                let text = String(decoding: completeData, as: UTF8.self)
                                var linesArray = text.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "\r", with: "") }
                                if linesArray.last?.isEmpty == true { linesArray.removeLast() }

                                let finalLines = linesArray
                                guard !finalLines.isEmpty else { continue }

                                await MainActor.run { [weak self] in
                                    guard let self = self else { return }
                                    if let idx = self.openTabs.firstIndex(where: { $0.id == tabID }),
                                       let content = self.openTabs[idx].content {
                                        let baseOffset = content.count
                                        content.appendLines(finalLines)
                                        self.appendHighlightsForLiveTail(with: finalLines, startingAt: baseOffset)
                                        self.generateMinimapData(for: tabID)
                                        self.generateTimelineData(for: tabID)
                                        self.appendFilterForLiveTail(with: finalLines, startingAt: baseOffset)
                                        self.objectWillChange.send()
                                        if self.followTail {
                                            DispatchQueue.main.async {
                                                NotificationCenter.default.post(name: topPaneScrollToBottomNotification, object: nil)
                                                // Note: we already post bottom pane notification in appendFilterForLiveTail
                                            }
                                        }
                                    }
                                }
                            } else {
                                remainderData = dataToProcess
                            }
                        }
                    } catch {
                        print("Live tail read error: \(error)")
                    }
                    try? fileHandle.close()
                }
            }
        }
        liveTailTasks[tabID] = tailTask
    }

    func stopLiveTailing() {
        // Cancel all existing tail tasks
        for task in liveTailTasks.values {
            task.cancel()
        }
        liveTailTasks.removeAll()
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
                    NotificationCenter.default.post(name: bottomPaneScrollToBottomNotification, object: nil)
                }
            }
        }
    }

    func appendHighlightsForLiveTail(with newLines: [String], startingAt originalStartIndex: Int) {
        guard let tabID = selectedTabID,
              let tabIndex = openTabs.firstIndex(where: { $0.id == tabID })
        else { return }

        let activeRules = highlightRules.filter { $0.isEnabled && $0.compiledRegex != nil }
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
