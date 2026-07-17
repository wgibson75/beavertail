import Foundation

/// Coordinates the CPU-heavy index scans across concurrently-loading tabs.
///
/// Policy: **only the currently-selected tab's index build runs.** Every other
/// tab's build parks at the next segment boundary and stays paused until its tab
/// is selected again. This means that when the user rapidly clicks through several
/// restored tabs (kicking off a load for each) and then settles on one, the
/// background builds for the tabs they are *not* looking at immediately pause,
/// handing all cores to the visible tab — and each paused build silently resumes
/// the moment its tab is reselected.
///
/// The scan slot is handed off at segment boundaries (segments are capped at
/// 32 MB, i.e. a small fraction of a second of scanning), so switching tabs pauses
/// the old build almost immediately and starts/continues the new one right away.
/// Keeping the segment cap small is what makes switching to a small-log tab feel
/// instant even while a large tab is mid-scan.
final class IndexScanScheduler: @unchecked Sendable {
    private let cond = NSCondition()
    /// True while some build currently holds the single scan slot.
    private var busy = false
    /// The tab the user is currently viewing; only its build may scan.
    private var priorityTabID: UUID?
    /// Tabs whose builds should abort (e.g. the tab was closed) so a parked build
    /// thread doesn't stay blocked forever.
    private var cancelledTabs: Set<UUID> = []

    /// Updates which tab is visible. Called whenever the selected tab changes so the
    /// newly-visible tab's build can proceed and every other build parks.
    func setPriorityTab(_ id: UUID?) {
        cond.lock()
        priorityTabID = id
        // Wake every parked build so the new priority build takes the slot and the
        // others re-evaluate and step back.
        cond.broadcast()
        cond.unlock()
    }

    /// Marks a tab's build as cancelled (its tab was closed) and wakes any parked
    /// build so it can observe the cancellation and exit instead of blocking forever.
    func cancel(tabID: UUID) {
        cond.lock()
        cancelledTabs.insert(tabID)
        cond.broadcast()
        cond.unlock()
    }

    /// Blocks until this build may scan its next segment — i.e. until its tab is the
    /// selected (priority) tab and no other build holds the scan slot. Returns
    /// `false` if the build should abort (its tab was closed), in which case the
    /// caller must stop indexing.
    func acquire(tabID: UUID) -> Bool {
        cond.lock()
        while (priorityTabID != tabID || busy) && !cancelledTabs.contains(tabID) {
            cond.wait()
        }
        let cancelled = cancelledTabs.contains(tabID)
        if !cancelled { busy = true }
        cond.unlock()
        return !cancelled
    }

    /// Releases the scan slot after a segment so a waiting build (the priority tab)
    /// can proceed.
    func release() {
        cond.lock()
        busy = false
        cond.broadcast()
        cond.unlock()
    }
}
