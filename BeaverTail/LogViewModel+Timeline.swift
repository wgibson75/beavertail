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
        let markCGColor = isDark ? CGColor(red: 1, green: 1, blue: 1, alpha: 1) : CGColor(red: 0, green: 0, blue: 0, alpha: 1)

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

        // Map activeRules to the cached indices
        let mappedCacheIndices = activeRules.compactMap { rule -> Int? in
            activeRuleIDsCache.firstIndex(of: rule.id)
        }

        let logTotalLines = content.count
        // Restrict the timeline to the visible range when lines are hidden.
        let vBounds = openTabs[index].visibleBounds(for: logTotalLines)
        let rangeStart = vBounds?.lower ?? 0
        let rangeEnd = vBounds.map { $0.upper + 1 } ?? logTotalLines
        let rangeSpan = max(0, rangeEnd - rangeStart)
        timelineTasks[tabID] = Task.detached(priority: .utility) { [weak self] in
            let colWidth = 40
            let imgHeight = 6000

            let bSearch: ([Int], Int) -> Int = { arr, el in
                var low = 0
                var high = arr.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if arr[mid] < el { low = mid + 1 } else { high = mid }
                }
                return low
            }

            // Maps a bucket row to its inclusive-start / exclusive-end original
            // line indices within the (possibly restricted) visible range.
            let bucketBounds: (Int) -> (Int, Int) = { bucket in
                let start = rangeStart + Int(Double(bucket) * Double(rangeSpan) / Double(imgHeight))
                let end = bucket == imgHeight - 1
                    ? rangeEnd
                    : rangeStart + Int(Double(bucket + 1) * Double(rangeSpan) / Double(imgHeight))
                return (start, end)
            }

            var newTimelineMatches: [[Int]] = Array(repeating: [], count: activeRules.count)
            var bucketMatchCounts = Array(repeating: Array(repeating: 0, count: activeRules.count), count: imgHeight)
            var bucketSampledCounts = [Int](repeating: 0, count: imgHeight)

            for bucket in 0..<imgHeight {
                if Task.isCancelled { return }
                let (bucketStart, bucketEnd) = bucketBounds(bucket)
                if bucketStart >= rangeEnd { break }

                if isFiltered {
                    let fLower = bSearch(filteredIndices, bucketStart)
                    let fUpper = bSearch(filteredIndices, bucketEnd)
                    let countInBucket = fUpper - fLower
                    if countInBucket == 0 { continue }

                    var matchCounts = [Int](repeating: 0, count: activeRules.count)
                    for (i, cacheIdx) in mappedCacheIndices.enumerated() {
                        let matches = cache[cacheIdx]
                        var count = 0
                        var firstHitLine: Int?
                        // Fast intersection for this bucket
                        for fIdx in fLower..<fUpper {
                            let lineIdx = filteredIndices[fIdx]
                            let rLower = bSearch(matches, lineIdx)
                            if rLower < matches.count && matches[rLower] == lineIdx {
                                count += 1
                                if firstHitLine == nil { firstHitLine = lineIdx }
                            }
                        }
                        matchCounts[i] = count
                        if let hit = firstHitLine {
                            newTimelineMatches[i].append(hit)
                        }
                    }
                    bucketMatchCounts[bucket] = matchCounts
                    bucketSampledCounts[bucket] = countInBucket

                } else {
                    let countInBucket = bucketEnd - bucketStart
                    if countInBucket == 0 { continue }

                    var matchCounts = [Int](repeating: 0, count: activeRules.count)
                    for (i, cacheIdx) in mappedCacheIndices.enumerated() {
                        let matches = cache[cacheIdx]
                        let lower = bSearch(matches, bucketStart)
                        let upper = bSearch(matches, bucketEnd)
                        let count = upper - lower
                        matchCounts[i] = count
                        if count > 0 {
                            newTimelineMatches[i].append(matches[lower])
                        }
                    }
                    bucketMatchCounts[bucket] = matchCounts
                    bucketSampledCounts[bucket] = countInBucket
                }
            }

            if Task.isCancelled { return }

            var displayedRuleIndices: [Int] = []
            for i in 0..<activeRules.count {
                if !newTimelineMatches[i].isEmpty {
                    displayedRuleIndices.append(i)
                }
            }

            let numColumns = displayedRuleIndices.count + (hasMarks ? 1 : 0)
            let imgWidth = numColumns * colWidth

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: max(1, imgWidth), height: max(1, imgHeight),
                bitsPerComponent: 8, bytesPerRow: max(1, imgWidth) * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }

            ctx.translateBy(x: 0, y: CGFloat(imgHeight))
            ctx.scaleBy(x: 1.0, y: -1.0)

            var finalMatchesToSave: [[Int]] = []
            if hasMarks {
                finalMatchesToSave.append(sortedMarks)
            }
            for i in displayedRuleIndices {
                finalMatchesToSave.append(newTimelineMatches[i])
            }

            let activeRuleIDsThatMatched = displayedRuleIndices.map { activeRules[$0].id }
            let ruleOffset = hasMarks ? 1 : 0

            if hasMarks {
                for bucket in 0..<imgHeight {
                    let (bucketStart, bucketEnd) = bucketBounds(bucket)
                    if bucketStart >= rangeEnd { break }

                    let mLower = bSearch(sortedMarks, bucketStart)
                    let mUpper = bSearch(sortedMarks, bucketEnd)
                    if mLower < mUpper {
                        let dotWidth = CGFloat(colWidth) * 0.8
                        let dotHeight = 4.0
                        let rect = CGRect(x: (CGFloat(colWidth) - dotWidth) / 2, y: CGFloat(bucket), width: dotWidth, height: dotHeight)
                        ctx.setFillColor(markCGColor)
                        ctx.fillEllipse(in: rect)
                    }
                }
            }

            for bucket in 0..<imgHeight {
                let totalSampled = bucketSampledCounts[bucket]
                if totalSampled == 0 { continue }

                let counts = bucketMatchCounts[bucket]
                for (dispIdx, originalIdx) in displayedRuleIndices.enumerated() {
                    let count = counts[originalIdx]
                    if count > 0 {
                        let density = CGFloat(count) / CGFloat(totalSampled)
                        let alpha = max(0.45, min(1.0, density * 1.6))
                        if let scaledColor = ruleColors[originalIdx].copy(alpha: alpha) {
                            ctx.setFillColor(scaledColor)
                            let colIdx = dispIdx + ruleOffset
                            let xOffset = colIdx * colWidth
                            let dotWidth = CGFloat(colWidth) * 0.8
                            let dotHeight = 2.0
                            ctx.fillEllipse(in: CGRect(x: CGFloat(xOffset) + (CGFloat(colWidth) - dotWidth) / 2,
                                                       y: CGFloat(bucket),
                                                       width: dotWidth,
                                                       height: dotHeight))
                        }
                    }
                }
            }

            guard !Task.isCancelled, let cgImage = ctx.makeImage() else { return }
            let bitmap = NSImage(cgImage: cgImage, size: NSSize(width: max(1, imgWidth), height: imgHeight))

            let finalTimelineMatches = finalMatchesToSave
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let freshIndex = self.openTabs.firstIndex(where: { $0.id == tabID }) {
                    self.openTabs[freshIndex].timelineImage = bitmap
                    self.openTabs[freshIndex].timelineMatches = finalTimelineMatches
                    self.openTabs[freshIndex].timelineActiveRuleIDs = activeRuleIDsThatMatched
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
