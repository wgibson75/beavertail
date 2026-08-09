//
//  VectorscanBenchmarkTests.swift
//  BeaverTailTests
//
//  Measures whether the Vectorscan-accelerated regex path actually speeds up the
//  scan hot loops, by timing the SAME work with `LogContent.vectorscanEnabled`
//  toggled on vs. off across three representative workloads:
//    1. a plain literal filter (handled by the byte scanner — Vectorscan not involved),
//    2. a complex regex filter with no usable literal pre-filter (regex runs on every
//       line — the case Vectorscan is meant to help),
//    3. highlight generation with many rules (extractAllMatches).
//
//  Each scenario also asserts the on/off results are IDENTICAL, so the comparison is
//  apples-to-apples (and doubles as a large-input parity check). Timings are printed
//  to the test log; the assertions never fail on timing (perf varies by machine).
//

import XCTest
@testable import BeaverTail

final class VectorscanBenchmarkTests: XCTestCase {

    /// Large synthetic log shared across the scenarios (built once).
    private static let content: LogContent = {
        let count = 400_000
        var lines: [String] = []
        lines.reserveCapacity(count)
        for i in 0..<count {
            switch i % 5 {
            case 0: lines.append("2026-08-09 12:00:00 INFO user\(i) connected from 10.0.0.\(i % 256)")
            case 1: lines.append("2026-08-09 12:00:01 ERROR failed to connect code=\(i % 1000)")
            case 2: lines.append("2026-08-09 12:00:02 DEBUG heartbeat seq=\(i)")
            case 3: lines.append("2026-08-09 12:00:03 WARN latency 12.34 ms on service-\(i % 50)")
            default: lines.append("plain text line number \(i) with value 3.1415 end")
            }
        }
        return LogContent.fromLines(lines)
    }()

    override func tearDown() {
        LogContent.vectorscanEnabled = true
        super.tearDown()
    }

    // MARK: - Timing helpers

    /// Runs `block` once to warm up, then returns the best (minimum) wall time in
    /// milliseconds over `iterations` runs.
    private func bestMillis(iterations: Int = 4, _ block: () -> Void) -> Double {
        block()
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            best = min(best, elapsed)
        }
        return best
    }

    /// Runs one filter pass and returns the number of matching lines.
    private func runFilter(_ pattern: String) -> Int {
        let matcher = LineMatcher.make(pattern: pattern, caseInsensitive: false)!
        let box = CountBox()
        Self.content.filterMatches(matcher: matcher, progress: ScanProgress(total: Self.content.count)) { latest in
            box.observe(latest.count)
        }
        return box.maximum
    }

    /// Runs one highlight pass over many matchers and returns the total match count.
    private func runHighlights(_ patterns: [String]) -> Int {
        let matchers = patterns.map { LineMatcher.make(pattern: $0, caseInsensitive: false)! }
        let box = CountBox()
        Self.content.extractAllMatches(matchers: matchers) { snapshot, force in
            if force { box.observe(snapshot.reduce(0) { $0 + $1.count }) }
        }
        return box.maximum
    }

    private func report(_ name: String, on: Double, off: Double, matches: Int) {
        let speedup = off / on
        print(String(
            format: "[Vectorscan bench] %@: on=%.1f ms  off=%.1f ms  speedup=%.2fx  (matches=%d)",
            name, on, off, speedup, matches
        ))
    }

    // MARK: - Scenarios

    func testBenchmarkLiteralFilter() {
        // Literal — served by the byte scanner; Vectorscan is not on this path, so we
        // expect ~parity. Included as a baseline / sanity reference.
        LogContent.vectorscanEnabled = true
        let onMatches = runFilter("ERROR")
        let on = bestMillis { _ = runFilter("ERROR") }
        LogContent.vectorscanEnabled = false
        let offMatches = runFilter("ERROR")
        let off = bestMillis { _ = runFilter("ERROR") }
        XCTAssertEqual(onMatches, offMatches, "literal on/off must match")
        report("literal 'ERROR'", on: on, off: off, matches: onMatches)
    }

    func testBenchmarkComplexRegexFilter() {
        // "[0-9]+\.[0-9]+" derives no literal pre-filter → the regex runs on EVERY
        // line. This is the case Vectorscan is meant to accelerate.
        let pattern = "[0-9]+\\.[0-9]+"
        LogContent.vectorscanEnabled = true
        let onMatches = runFilter(pattern)
        let on = bestMillis { _ = runFilter(pattern) }
        LogContent.vectorscanEnabled = false
        let offMatches = runFilter(pattern)
        let off = bestMillis { _ = runFilter(pattern) }
        XCTAssertEqual(onMatches, offMatches, "complex-regex on/off must match")
        report("regexOnly '[0-9]+\\.[0-9]+'", on: on, off: off, matches: onMatches)
    }

    func testBenchmarkManyHighlightRules() {
        let patterns = [
            "INFO", "ERROR", "DEBUG", "WARN",
            "user[0-9]+", "code=[0-9]+", "seq=[0-9]+", "service-[0-9]+",
            "[0-9]+\\.[0-9]+", "10\\.0\\.0\\.[0-9]+", "connect", "latency"
        ]
        LogContent.vectorscanEnabled = true
        let onMatches = runHighlights(patterns)
        let on = bestMillis(iterations: 3) { _ = runHighlights(patterns) }
        LogContent.vectorscanEnabled = false
        let offMatches = runHighlights(patterns)
        let off = bestMillis(iterations: 3) { _ = runHighlights(patterns) }
        XCTAssertEqual(onMatches, offMatches, "highlight on/off must match")
        report("highlights (\(patterns.count) rules)", on: on, off: off, matches: onMatches)
    }

    /// Diagnostic: how long does the upfront Vectorscan compilation cost as the
    /// number of highlight rules grows? This is the single-threaded, non-cancellable
    /// work that runs at the START of every `extractAllMatches`, so if it scales
    /// badly it can stall highlight generation on large logs with many filters.
    func testCompileScalingWithManyRules() {
        for ruleCount in [10, 25, 50, 100, 200] {
            var patterns: [String] = []
            for i in 0..<ruleCount {
                // Mix of literals and simple regex, like a real highlight set.
                patterns.append(i % 2 == 0 ? "TOKEN\(i)" : "id\(i)=[0-9]+")
            }
            let matchers = patterns.map { LineMatcher.make(pattern: $0, caseInsensitive: false)! }

            // Time the fused multi-pattern compile alone.
            let expressions = matchers.compactMap { $0.vectorscanFusibleExpression }
            let fusedMs = bestMillis(iterations: 3) {
                _ = VectorscanMultiProgram(expressions: expressions)
            }
            // Time the per-matcher single-pattern compiles (what buildScanParams does).
            let singleMs = bestMillis(iterations: 3) {
                for expression in expressions {
                    _ = VectorscanProgram(pattern: expression.pattern, caseInsensitive: expression.caseInsensitive)
                }
            }
            print(String(
                format: "[Vectorscan compile] %d rules: fused=%.1f ms  per-matcher-single=%.1f ms",
                ruleCount, fusedMs, singleMs
            ))
        }
    }
}

/// Thread-safe max-count collector (the scan callbacks fire from worker threads).
private final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func observe(_ count: Int) {
        lock.lock(); value = max(value, count); lock.unlock()
    }
    var maximum: Int {
        lock.lock(); defer { lock.unlock() }; return value
    }
}
