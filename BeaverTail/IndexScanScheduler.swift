import Foundation

/// Coordinates the CPU-heavy index scans across concurrently-loading tabs.
///
/// Two guarantees are provided:
///
/// 1. **Only ONE all-core segment scan runs at a time.** Each `scanSegment` uses
///    every core (via `DispatchQueue.concurrentPerform`), so allowing two builds
///    to scan simultaneously would saturate the machine and starve the main
///    thread — freezing the progressive top-pane display. The scheduler funnels
///    all scans through a single logical "scan slot".
///
/// 2. **The currently-visible tab's build always wins the slot.** Builds acquire
///    the slot per segment and release it between segments, so at every segment
///    boundary a background build will step aside for the visible tab's build.
///    Without this, a restored-session tab that began indexing first would hold
///    the slot to completion, delaying the file the user actually just opened and
///    is looking at.
///
/// The scan slot is handed off at segment boundaries (segments are capped at
/// 256 MB, i.e. a fraction of a second of scanning), which is fine-grained enough
/// that the visible tab starts appearing almost immediately even when a huge
/// background file is mid-index.
final class IndexScanScheduler: @unchecked Sendable {
    private let cond = NSCondition()
    /// True while some build currently holds the single scan slot.
    private var busy = false
    /// The tab the user is currently viewing; its build gets priority.
    private var priorityTabID: UUID?
    /// Number of parked builds that belong to the priority tab. Non-priority
    /// builds defer to the slot while this is greater than zero.
    private var priorityWaiters = 0

    /// Updates which tab is visible. Called whenever the selected tab changes so a
    /// newly-visible tab's in-flight build can preempt a background build at the
    /// next segment boundary.
    func setPriorityTab(_ id: UUID?) {
        cond.lock()
        priorityTabID = id
        // Wake every parked build so they re-evaluate priority against the new
        // visible tab (the new priority build takes the slot; others step back).
        cond.broadcast()
        cond.unlock()
    }

    /// Blocks until this build may scan its next segment. A build that is not the
    /// priority tab yields to any priority-tab build that is currently waiting.
    func acquire(tabID: UUID) {
        cond.lock()
        var countedAsPriority = false
        while true {
            let isPriority = (priorityTabID == tabID)
            // Keep the priority-waiter count consistent with our live status: the
            // visible tab can change while we're parked here.
            if isPriority && !countedAsPriority {
                priorityWaiters += 1
                countedAsPriority = true
                cond.broadcast()
            } else if !isPriority && countedAsPriority {
                priorityWaiters -= 1
                countedAsPriority = false
                cond.broadcast()
            }

            let blockedByPriority = !isPriority && priorityWaiters > 0
            if !busy && !blockedByPriority { break }
            cond.wait()
        }
        if countedAsPriority { priorityWaiters -= 1 }
        busy = true
        cond.unlock()
    }

    /// Releases the scan slot after a segment so a waiting build (preferring the
    /// priority tab) can proceed.
    func release() {
        cond.lock()
        busy = false
        cond.broadcast()
        cond.unlock()
    }
}
