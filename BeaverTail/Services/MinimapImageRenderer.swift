//
//  MinimapImageRenderer.swift
//  BeaverTail
//
//  Service layer: pure Core Graphics rendering for the minimap highlight strip.
//  The view model gathers the inputs (which rules matched which lines, the
//  visible range, the target image size) and hands them to this UI-state-free
//  renderer, which does the bucketing + drawing off the main actor and returns a
//  finished image. A mirror of `TimelineImageRenderer`; keeping CoreGraphics out
//  of `LogViewModel` makes the rendering independently reasoned-about and
//  testable via the pure `minimapFills` core.
//

import AppKit
import Foundation

/// Everything the minimap renderer needs, captured as plain values so the heavy
/// work can run on a background task without touching view-model state.
struct MinimapRenderInput {
    /// Background colour for each active rule (indexed by active-rule position),
    /// aligned 1:1 with `cache`.
    let colors: [CGColor]
    /// Cached matching line indices, one sorted array per rule.
    let cache: [[Int]]
    /// Inclusive-start / exclusive-end of the visible original-line range.
    let rangeStart: Int
    let rangeEnd: Int
    let imageWidth: Int
    let imageHeight: Int
}

/// One rectangle to paint on the minimap: a full-width band `height` pixels tall
/// starting at pixel row `yTop`, filled with `color` at `alpha`.
struct MinimapFill: Equatable {
    let yTop: Int
    let height: Int
    let color: CGColor
    let alpha: CGFloat
}

/// Renders the minimap highlight strip. All methods are pure and free of
/// view-model or AppKit-view state; the only side effect is allocating an image.
enum MinimapImageRenderer {

    /// Produces the minimap image, or `nil` when the visible range is empty, an
    /// image context cannot be created, or the enclosing task is cancelled (a
    /// newer render has superseded this one). `nonisolated` so the heavy work runs
    /// on a background task, not the main actor. A valid but match-free input
    /// still yields a (transparent) image, matching the previous inline behaviour.
    nonisolated static func render(_ input: MinimapRenderInput) -> NSImage? {
        let rangeSpan = input.rangeEnd - input.rangeStart
        guard rangeSpan > 0 else { return nil }

        let width = input.imageWidth
        let height = input.imageHeight
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard width > 0, height > 0, let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let fills = minimapFills(for: input, isCancelled: { Task.isCancelled })
        if Task.isCancelled { return nil }

        for fill in fills {
            guard let scaledColor = fill.color.copy(alpha: fill.alpha) else { continue }
            ctx.setFillColor(scaledColor)
            ctx.fill(CGRect(x: 0, y: fill.yTop, width: width, height: fill.height))
        }

        guard !Task.isCancelled, let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// The pure bucketing core: computes the list of fill bands (in draw order)
    /// for the given input. Two mutually-exclusive regimes, keyed on whether there
    /// are more visible lines than pixel rows:
    ///
    /// - **MANY** (`rangeSpan >= imageHeight`): each pixel row samples a bucket of
    ///   lines. A bucket with any matches is drawn as a 1px band coloured by the
    ///   highest-priority (earliest) rule that matched in it, its alpha scaled by
    ///   match density.
    /// - **FEW** (`rangeSpan < imageHeight`): each visible matched line spans one
    ///   or more pixel rows and is drawn as a full opaque band. Lower-priority
    ///   rules are emitted first so the highest-priority rule wins on overlap.
    ///
    /// `isCancelled` is polled so a superseded render can bail promptly.
    nonisolated static func minimapFills(
        for input: MinimapRenderInput,
        isCancelled: () -> Bool = { false }
    ) -> [MinimapFill] {
        let rangeStart = input.rangeStart
        let rangeEnd = input.rangeEnd
        let rangeSpan = rangeEnd - rangeStart
        let imgHeight = input.imageHeight
        let cache = input.cache
        let colors = input.colors
        guard rangeSpan > 0 else { return [] }

        let bSearch: ([Int], Int) -> Int = { arr, el in
            var low = 0
            var high = arr.count
            while low < high {
                let mid = low + (high - low) / 2
                if arr[mid] < el { low = mid + 1 } else { high = mid }
            }
            return low
        }

        var fills: [MinimapFill] = []

        // MANY-lines regime: one bucket per pixel row.
        if rangeSpan >= imgHeight {
            for bucket in 0..<imgHeight {
                if isCancelled() { return fills }
                let bucketStart = rangeStart + Int(Double(bucket) * Double(rangeSpan) / Double(imgHeight))
                if bucketStart >= rangeEnd { break }

                let bucketEnd = bucket == imgHeight - 1
                    ? rangeEnd
                    : rangeStart + Int(Double(bucket + 1) * Double(rangeSpan) / Double(imgHeight))
                let linesInBucket = bucketEnd - bucketStart
                if linesInBucket <= 0 { continue }

                var matchCount = 0
                var matchColor: CGColor?
                for mIdx in 0..<cache.count where mIdx < colors.count {
                    let matches = cache[mIdx]
                    let lower = bSearch(matches, bucketStart)
                    let upper = bSearch(matches, bucketEnd)
                    let count = upper - lower
                    if count > 0 {
                        matchCount += count
                        if matchColor == nil { matchColor = colors[mIdx] }
                    }
                }

                guard matchCount > 0, let color = matchColor else { continue }
                let density = CGFloat(matchCount) / CGFloat(linesInBucket)
                let alpha = max(0.45, min(1.0, density * 5.0))
                fills.append(MinimapFill(yTop: bucket, height: 1, color: color, alpha: alpha))
            }
            return fills
        }

        // FEW-lines regime: each matched visible line fills its full band. Draw
        // lower-priority rules first so the highest-priority rule wins on overlap.
        for mIdx in stride(from: cache.count - 1, through: 0, by: -1) {
            if isCancelled() { return fills }
            guard mIdx < colors.count else { continue }
            let color = colors[mIdx]
            for line in cache[mIdx] where line >= rangeStart && line < rangeEnd {
                let rel = line - rangeStart
                let yTop = Int(Double(rel) * Double(imgHeight) / Double(rangeSpan))
                let yBot = Int(Double(rel + 1) * Double(imgHeight) / Double(rangeSpan))
                fills.append(MinimapFill(yTop: yTop, height: max(1, yBot - yTop), color: color, alpha: 1.0))
            }
        }
        return fills
    }
}
