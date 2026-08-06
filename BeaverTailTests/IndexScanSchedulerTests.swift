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
        DispatchQueue.global().async {
            if scheduler.acquire(tabID: idB) { acquired.fulfill() }
            scheduler.release()
        }
        // idB is not the priority tab, so it parks until we prioritise it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            scheduler.setPriorityTab(idB)
        }
        wait(for: [acquired], timeout: 3)
    }

    // MARK: - Mutual exclusion

    func testSecondAcquireBlocksUntilRelease() {
        let scheduler = IndexScanScheduler()
        let id = UUID()
        scheduler.setPriorityTab(id)
        XCTAssertTrue(scheduler.acquire(tabID: id)) // first holder holds the slot

        let secondAcquired = expectation(description: "second acquire proceeds after release")
        DispatchQueue.global().async {
            if scheduler.acquire(tabID: id) { secondAcquired.fulfill() }
            scheduler.release()
        }
        // The second acquire must wait until the first holder releases the slot.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            scheduler.release()
        }
        wait(for: [secondAcquired], timeout: 3)
    }

    // MARK: - Cancellation

    func testCancelUnblocksWaitingTab() {
        let scheduler = IndexScanScheduler()
        let idA = UUID(), idB = UUID()
        scheduler.setPriorityTab(idA)

        let returned = expectation(description: "cancelled acquire returns false")
        DispatchQueue.global().async {
            let ok = scheduler.acquire(tabID: idB) // parks (idB not priority)
            XCTAssertFalse(ok, "a cancelled tab's acquire must return false")
            returned.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            scheduler.cancel(tabID: idB)
        }
        wait(for: [returned], timeout: 3)
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
