//
//  IndexScanSchedulerTests.swift
//  BeaverTailTests
//
//  Item 13: the NSCondition-backed scan-slot scheduler (mutual exclusion,
//  prioritisation, cancellation).
//

import XCTest
@testable import BeaverTail

final class IndexScanSchedulerTests: XCTestCase {

    // MARK: - Happy path

    func testPriorityTabAcquiresImmediately() {
        let scheduler = IndexScanScheduler()
        let id = UUID()
        scheduler.setPriorityTab(id)
        XCTAssertTrue(scheduler.acquire(tabID: id))
        scheduler.release()
    }

    // MARK: - Prioritisation

    func testNonPriorityTabProceedsOncePrioritised() {
        let scheduler = IndexScanScheduler()
        let idA = UUID(), idB = UUID()
        scheduler.setPriorityTab(idA)

        let acquired = expectation(description: "idB acquired after prioritisation")
        // Dedicated thread (not the shared GCD pool) so full-suite pool saturation
        // can't delay this block past the timeout and cause an intermittent failure.
        let worker = Thread {
            if scheduler.acquire(tabID: idB) { acquired.fulfill() }
            scheduler.release()
        }
        worker.start()
        // idB is not the priority tab, so it parks until we prioritise it.
        Thread.sleep(forTimeInterval: 0.1)
        scheduler.setPriorityTab(idB)
        wait(for: [acquired], timeout: 5)
    }

    // MARK: - Mutual exclusion

    func testSecondAcquireBlocksUntilRelease() {
        let scheduler = IndexScanScheduler()
        let id = UUID()
        scheduler.setPriorityTab(id)
        XCTAssertTrue(scheduler.acquire(tabID: id)) // first holder holds the slot

        let secondAcquired = expectation(description: "second acquire proceeds after release")
        // Dedicated thread (not the shared GCD pool) so full-suite pool saturation
        // can't delay this block past the timeout and cause an intermittent failure.
        let worker = Thread {
            if scheduler.acquire(tabID: id) { secondAcquired.fulfill() }
            scheduler.release()
        }
        worker.start()
        // The second acquire must wait until the first holder releases the slot.
        Thread.sleep(forTimeInterval: 0.1)
        scheduler.release()
        wait(for: [secondAcquired], timeout: 5)
    }

    // MARK: - Cancellation

    func testCancelUnblocksWaitingTab() {
        let scheduler = IndexScanScheduler()
        let idA = UUID(), idB = UUID()
        scheduler.setPriorityTab(idA)

        let started = expectation(description: "acquire thread started")
        let returned = expectation(description: "cancelled acquire returns false")

        // Run the parked acquire on a dedicated thread rather than the shared GCD
        // global-queue pool. When the full suite runs, the pool can be saturated by
        // the other concurrency tests (which park several threads in cond.wait()),
        // which would otherwise delay this test's dispatched blocks past the timeout
        // and make it fail intermittently. A dedicated thread is always schedulable.
        let worker = Thread {
            started.fulfill()
            let ok = scheduler.acquire(tabID: idB) // parks (idB not priority)
            XCTAssertFalse(ok, "a cancelled tab's acquire must return false")
            returned.fulfill()
        }
        worker.start()

        // Ensure the worker is running, give it a moment to reach the park, then
        // cancel from the test's own thread. Cancellation is correct whether or not
        // the worker has parked yet, so this can't lose a wakeup.
        wait(for: [started], timeout: 5)
        Thread.sleep(forTimeInterval: 0.1)
        scheduler.cancel(tabID: idB)

        wait(for: [returned], timeout: 5)
    }

    // MARK: - Edge cases

    func testReleaseWithoutAcquireIsSafe() {
        let scheduler = IndexScanScheduler()
        scheduler.release() // must not crash or deadlock
    }

    // MARK: - Stress / single-holder invariant

    func testConcurrentAcquireReleaseNeverAllowsTwoHolders() {
        let scheduler = IndexScanScheduler()
        let id = UUID()
        scheduler.setPriorityTab(id)

        let lock = NSLock()
        var holders = 0
        var violation = false

        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<200 where scheduler.acquire(tabID: id) {
                    lock.lock()
                    holders += 1
                    if holders > 1 { violation = true }
                    holders -= 1
                    lock.unlock()
                    scheduler.release()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        XCTAssertFalse(violation, "the scan slot must never be held by two builds at once")
    }
}
