//
//  FileLoadService.swift
//  BeaverTail
//
//  Service layer: memory-mapping a log file and building its line index
//  incrementally, publishing the growing content as segments are scanned. The
//  view model previously inlined this in `loadNewTab` and `triggerLazyLoadForTab`
//  (mapping via `LogContent.mappedEmpty`, driving `buildIndex`, and hand-rolling
//  the publish-throttle bookkeeping). That mechanic now lives here — UI-free and
//  off the main actor — so both call sites share one implementation and the
//  throttle decision is independently testable. The view model keeps only the
//  orchestration: dispatching the work and applying each snapshot to tab state.
//

import Foundation

/// Maps + incrementally indexes a log file, coalescing intermediate UI publishes.
enum FileLoadService {
    /// Minimum gap between *intermediate* partial publishes. The very first
    /// segment is always published immediately so lines appear as early as
    /// possible; further partials inside this window are coalesced so a fast scan
    /// of a huge file doesn't flood the main thread with reloads.
    nonisolated static let publishThrottleMilliseconds: UInt64 = 100

    /// Whether a partial snapshot should be published now.
    ///
    /// - The first partial (`didPublishFirst == false`) always publishes, so the
    ///   earliest lines appear immediately regardless of elapsed time.
    /// - Subsequent partials publish only once at least `throttleMilliseconds`
    ///   have elapsed since the previous publish.
    nonisolated static func shouldPublishPartial(
        didPublishFirst: Bool,
        elapsedMilliseconds: UInt64,
        throttleMilliseconds: UInt64 = publishThrottleMilliseconds
    ) -> Bool {
        !didPublishFirst || elapsedMilliseconds >= throttleMilliseconds
    }

    /// Memory-maps `url` and builds its line index incrementally, returning the
    /// fully-indexed `LogContent`.
    ///
    /// The file is mapped (never fully read into memory) and scanned in file order,
    /// so the earliest lines become available first. `onPartial` receives the
    /// growing content after each scanned segment, throttled via
    /// `shouldPublishPartial` (the first snapshot always fires). `onSegmentWillScan`
    /// / `onSegmentDidScan` bracket each segment's CPU-heavy parallel scan so the
    /// caller can gate scans through a shared scheduler.
    ///
    /// Runs synchronously on the calling (background) thread; callbacks are invoked
    /// on that same thread. Throws if the file cannot be mapped.
    nonisolated static func loadIncrementally(
        from url: URL,
        progress: ScanProgress,
        onSegmentWillScan: () -> Bool = { true },
        onSegmentDidScan: () -> Void = {},
        onPartial: (LogContent) -> Void
    ) throws -> LogContent {
        // Map the file (no full read into memory) and index it incrementally,
        // publishing the growing content after each segment so lines appear in the
        // top pane as early as possible instead of only once the whole (potentially
        // multi-GB) file has finished indexing.
        let content = try LogContent.mappedEmpty(from: url)

        var lastPublish = DispatchTime.now().uptimeNanoseconds
        var didPublishFirst = false
        content.buildIndex(
            progress: progress,
            onSegmentWillScan: onSegmentWillScan,
            onSegmentDidScan: onSegmentDidScan
        ) { partial in
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsedMs = (now &- lastPublish) / 1_000_000
            guard shouldPublishPartial(didPublishFirst: didPublishFirst, elapsedMilliseconds: elapsedMs) else { return }
            didPublishFirst = true
            lastPublish = now
            onPartial(partial)
        }
        return content
    }
}
