//
//  TestSupport.swift
//  BeaverTailTests
//
//  Shared helpers for the unit-test target.
//

import Foundation
import XCTest
@testable import BeaverTail

// MARK: - Scan result collectors

/// Thread-safe collector for the `onUpdate` callbacks emitted by the parallel
/// scans (`LogContent.filterMatches`). Those callbacks can fire from
/// `concurrentPerform` worker threads, so access is serialised. Tests assert
/// against `latest`, which — after the scan method returns — holds the final,
/// forced emit delivered synchronously on the calling thread.
final class MatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLatest: [Int] = []
    private var storedCallCount = 0

    func record(_ value: [Int]) {
        lock.lock()
        storedLatest = value
        storedCallCount += 1
        lock.unlock()
    }

    var latest: [Int] {
        lock.lock(); defer { lock.unlock() }
        return storedLatest
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return storedCallCount
    }
}

/// Thread-safe collector for the multi-matcher scan (`LogContent.extractAllMatches`).
final class MultiMatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLatest: [[Int]] = []
    private var storedCallCount = 0

    func record(_ value: [[Int]]) {
        lock.lock()
        storedLatest = value
        storedCallCount += 1
        lock.unlock()
    }

    var latest: [[Int]] {
        lock.lock(); defer { lock.unlock() }
        return storedLatest
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return storedCallCount
    }
}

// MARK: - Comparison source helper

/// Builds a `LogComparisonSource` from an in-memory array of lines.
func makeComparisonSource(_ lines: [String]) -> LogComparisonSource {
    LogComparisonSource(provider: ArrayLineProvider(lines: lines), count: lines.count)
}

// MARK: - Temporary log files

/// Writes `contents` to a unique temporary file and returns its URL. The caller
/// is responsible for removing it (see `removeTempFile`).
func writeTempFile(_ contents: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("beavertail-test-\(UUID().uuidString).log")
    try contents.data(using: .utf8)?.write(to: url)
    return url
}

func removeTempFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - UserDefaults isolation

/// The persistence-related keys `LogViewModel` reads on `init` and writes as tabs /
/// rules / history change. Tests that construct a `LogViewModel` snapshot and clear
/// these so each test starts from a clean, deterministic state and the developer's
/// real saved state is left untouched.
enum PersistedDefaults {
    static let keys = [
        "saved_highlight_rules",
        "saved_highlight_groups",
        "saved_filter_history_v1",
        "saved_recent_files_v1",
        "saved_session_bookmarks_v2"
    ]

    /// Snapshots and clears every key, returning the snapshot for later restoration.
    static func clear() -> [String: Any?] {
        var snapshot: [String: Any?] = [:]
        for key in keys {
            snapshot[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        return snapshot
    }

    static func restore(_ snapshot: [String: Any?]) {
        for (key, value) in snapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
