//
//  TimelineImageRenderer.swift
//  BeaverTail
//
//  Service layer: pure Core Graphics rendering for the per-rule density
//  timeline strip. The view model gathers the inputs (which rules are active,
//  which lines they matched, the visible range) and hands them to this
//  UI-state-free renderer, which does all the bucketing + drawing off the main
//  actor and returns a finished image. Keeping CoreGraphics out of LogViewModel
//  makes the rendering independently reasoned-about and testable.
//

import AppKit
import Foundation

/// Everything the timeline renderer needs, captured as plain values so the
/// heavy work can run on a background task without touching view-model state.
struct TimelineRenderInput {
    /// Background colour for each active rule (indexed by active-rule position).
    let ruleColors: [CGColor]
    /// Identifier for each active rule (indexed by active-rule position).
    let activeRuleIDs: [UUID]
    /// Maps each active rule to its slot in `cache`.
    let mappedCacheIndices: [Int]
    /// Cached matching line indices, one sorted array per cached rule.
    let cache: [[Int]]
    let isFiltered: Bool
    let filteredIndices: [Int]
    let sortedMarks: [Int]
    let hasMarks: Bool
    /// Inclusive-start / exclusive-end of the visible original-line range.
    let rangeStart: Int
    let rangeEnd: Int
    let isDark: Bool
}

/// The finished timeline artefacts to hand back to the view model.
struct TimelineRenderResult {
    let image: NSImage
    /// For each drawn column, the representative line indices (used for
    /// click-to-jump). Marks column first when present.
    let matches: [[Int]]
    /// Identifiers of the rules that actually produced a column.
    let activeRuleIDs: [UUID]
}

/// Renders the timeline strip. All methods are pure and free of view-model or
/// AppKit-view state; the only side effect is allocating an image.
enum TimelineImageRenderer {

    /// Produces the timeline image, or `nil` when the enclosing task is
    /// cancelled or an image context cannot be created. `nonisolated` so the
    /// heavy Core Graphics work runs on a background task, not the main actor.
    nonisolated static func render(_ input: TimelineRenderInput) -> TimelineRenderResult? {
        let ruleCount = input.ruleColors.count
        let rangeSpan = max(0, input.rangeEnd - input.rangeStart)

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
            let start = input.rangeStart + Int(Double(bucket) * Double(rangeSpan) / Double(imgHeight))
            let end = bucket == imgHeight - 1
                ? input.rangeEnd
                : input.rangeStart + Int(Double(bucket + 1) * Double(rangeSpan) / Double(imgHeight))
            return (start, end)
        }

        // Determine, per active rule, the lines it *actually* colours. When a
        // line matches several rules, only the highest-priority rule (earliest
        // in the active-rule order) colours it — matching the row renderer,
        // which stops at the first matching rule. Each rule therefore only
        // "owns" lines not already claimed by a higher-priority rule.
        var claimedLines = Set<Int>()
        var effectiveMatches: [[Int]] = Array(repeating: [], count: ruleCount)
        for (i, cacheIdx) in input.mappedCacheIndices.enumerated() {
            let matches = input.cache[cacheIdx]
            var owned: [Int] = []
            owned.reserveCapacity(matches.count)
            // `matches` is sorted, so `owned` stays sorted for the binary search.
            for line in matches where claimedLines.insert(line).inserted {
                owned.append(line)
            }
            effectiveMatches[i] = owned
        }

        var newTimelineMatches: [[Int]] = Array(repeating: [], count: ruleCount)
        var bucketMatchCounts = Array(repeating: Array(repeating: 0, count: ruleCount), count: imgHeight)
        var bucketSampledCounts = [Int](repeating: 0, count: imgHeight)

        for bucket in 0..<imgHeight {
            if Task.isCancelled { return nil }
            let (bucketStart, bucketEnd) = bucketBounds(bucket)
            if bucketStart >= input.rangeEnd { break }

            if input.isFiltered {
                let fLower = bSearch(input.filteredIndices, bucketStart)
                let fUpper = bSearch(input.filteredIndices, bucketEnd)
                let countInBucket = fUpper - fLower
                if countInBucket == 0 { continue }

                var matchCounts = [Int](repeating: 0, count: ruleCount)
                for i in input.mappedCacheIndices.indices {
                    let matches = effectiveMatches[i]
                    var count = 0
                    var firstHitLine: Int?
                    // Fast intersection for this bucket
                    for fIdx in fLower..<fUpper {
                        let lineIdx = input.filteredIndices[fIdx]
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

                var matchCounts = [Int](repeating: 0, count: ruleCount)
                for i in input.mappedCacheIndices.indices {
                    let matches = effectiveMatches[i]
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

        if Task.isCancelled { return nil }

        var displayedRuleIndices: [Int] = []
        for i in 0..<ruleCount where !newTimelineMatches[i].isEmpty {
            displayedRuleIndices.append(i)
        }

        let numColumns = displayedRuleIndices.count + (input.hasMarks ? 1 : 0)
        let imgWidth = numColumns * colWidth

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: max(1, imgWidth), height: max(1, imgHeight),
            bitsPerComponent: 8, bytesPerRow: max(1, imgWidth) * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(imgHeight))
        ctx.scaleBy(x: 1.0, y: -1.0)

        var finalMatchesToSave: [[Int]] = []
        if input.hasMarks {
            finalMatchesToSave.append(input.sortedMarks)
        }
        for i in displayedRuleIndices {
            finalMatchesToSave.append(newTimelineMatches[i])
        }

        let activeRuleIDsThatMatched = displayedRuleIndices.map { input.activeRuleIDs[$0] }
        let ruleOffset = input.hasMarks ? 1 : 0

        let markCGColor = input.isDark
            ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            : CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        if input.hasMarks {
            for bucket in 0..<imgHeight {
                let (bucketStart, bucketEnd) = bucketBounds(bucket)
                if bucketStart >= input.rangeEnd { break }

                let mLower = bSearch(input.sortedMarks, bucketStart)
                let mUpper = bSearch(input.sortedMarks, bucketEnd)
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
                    if let scaledColor = input.ruleColors[originalIdx].copy(alpha: alpha) {
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

        guard !Task.isCancelled, let cgImage = ctx.makeImage() else { return nil }
        let bitmap = NSImage(cgImage: cgImage, size: NSSize(width: max(1, imgWidth), height: imgHeight))

        return TimelineRenderResult(
            image: bitmap,
            matches: finalMatchesToSave,
            activeRuleIDs: activeRuleIDsThatMatched
        )
    }
}
