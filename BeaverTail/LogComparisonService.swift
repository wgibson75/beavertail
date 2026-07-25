//
//  LogComparisonService.swift
//  BeaverTail
//
//  Service layer: pure log-line signature + comparison logic for the "Find Unique
//  Lines" feature. Deliberately free of any AppKit / SwiftUI or view-model state so
//  it is unit-testable and can run off the main actor.
//

import Foundation

/// One source log for the comparison: a random-access line provider plus its line
/// count. Kept as a value so it can cross a concurrency boundary safely.
struct LogComparisonSource: Sendable {
    let provider: LineProvider
    let count: Int
}

/// Computes the "unique" log lines between a set of *problem* logs and a set of
/// *reference* logs by reducing every line to a normalised *signature* that ignores
/// the volatile parts of a line (timestamps, memory addresses, handle counters,
/// quoted labels, …).
///
/// This mirrors the reference `checklog.py` tool exactly: a signature is reported
/// only when it appears in **every** problem log (intersection) and in **none** of
/// the reference logs; the matching lines are emitted from the **first** problem log
/// in their original order.
enum LogComparisonService {

    /// Builds the signature for a single log line. Equivalent to the reference
    /// tool's regex substitution `"…"|'…'|[0-9a-fA-F]` → "" applied left-to-right:
    ///
    /// - A double- or single-quoted span (shortest match, like a non-greedy regex)
    ///   is removed wholesale, including its delimiters.
    /// - An unmatched quote (no closing delimiter) is **kept** and scanning
    ///   continues after it.
    /// - Every hexadecimal character (`0-9`, `a-f`, `A-F`) outside a quoted span is
    ///   removed.
    ///
    /// The net effect is that two lines of the same "flavour" — differing only by
    /// timestamps, addresses, incrementing handles or quoted text — collapse to the
    /// same signature.
    nonisolated static func signature(for line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        let count = scalars.count
        var result = String.UnicodeScalarView()
        result.reserveCapacity(count)

        var i = 0
        while i < count {
            let scalar = scalars[i]
            if scalar == "\"" || scalar == "'" {
                // Look for the matching closing quote (shortest span, matching the
                // non-greedy `".*?"` / `'.*?'` regex alternatives).
                var j = i + 1
                var close = -1
                while j < count {
                    if scalars[j] == scalar { close = j; break }
                    j += 1
                }
                if close >= 0 {
                    // Drop the whole quoted span [i...close].
                    i = close + 1
                    continue
                }
                // No closing quote: the delimiter isn't a span, so keep it (it isn't
                // a hex character) and carry on — exactly as the regex would.
                result.append(scalar)
                i += 1
                continue
            }
            if isHexScalar(scalar) {
                i += 1
                continue
            }
            result.append(scalar)
            i += 1
        }
        return String(result)
    }

    /// True for ASCII hexadecimal digits: `0-9`, `a-f`, `A-F`.
    nonisolated private static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (value >= 0x30 && value <= 0x39)   // 0-9
            || (value >= 0x41 && value <= 0x46)   // A-F
            || (value >= 0x61 && value <= 0x66)   // a-f
    }

    /// Returns the lines that are unique to the `sources` (problem) logs relative to
    /// the `others` (reference) logs, following `checklog.py`'s `compare_logs`:
    ///
    /// 1. Build the union of every reference log's signatures.
    /// 2. Build each problem log's signature set; intersect them so only signatures
    ///    present in **all** problem logs survive, then subtract the reference set.
    /// 3. Emit the lines from the **first** problem log whose signature survived, in
    ///    their original order, **without** de-duplication.
    ///
    /// `sources` must be supplied in problem-log order (the order the logs were
    /// marked); results are reported from `sources.first`. `isCancelled` is polled so
    /// a superseded comparison can bail out promptly. `progress`, when supplied, is
    /// incremented as lines are processed so a progress bar can track the work.
    ///
    /// The per-line signature computation — by far the dominant cost — is spread
    /// across **all** CPU cores (see `signatureSet(for:)`), so a large comparison
    /// saturates the machine rather than running on a single core.
    nonisolated static func uniqueLines(
        in sources: [LogComparisonSource],
        notIn others: [LogComparisonSource],
        isCancelled: @Sendable () -> Bool = { false },
        progress: ScanProgress? = nil
    ) -> [String] {
        guard let firstSource = sources.first else { return [] }

        // 1. Reference signatures: the union across every reference log.
        var referenceSignatures = Set<String>()
        for source in others {
            if isCancelled() { return [] }
            referenceSignatures.formUnion(signatureSet(for: source, isCancelled: isCancelled, progress: progress))
        }
        if isCancelled() { return [] }

        // 2. Per-problem-log signature sets, plus the first problem log's lines (in
        //    order) with their signatures — the candidates for the reported output.
        let firstLogEntries = orderedEntries(for: firstSource, isCancelled: isCancelled, progress: progress)
        if isCancelled() { return [] }

        var perLogSignatures: [Set<String>] = []
        perLogSignatures.reserveCapacity(sources.count)
        // The first problem log's signature set is derived from the entries we already
        // computed above, so it isn't scanned twice.
        perLogSignatures.append(Set(firstLogEntries.lazy.map { $0.sig }))
        for source in sources.dropFirst() {
            if isCancelled() { return [] }
            perLogSignatures.append(signatureSet(for: source, isCancelled: isCancelled, progress: progress))
        }

        // Signatures present in EVERY problem log, then minus the reference set.
        var uniqueSignatures = perLogSignatures[0]
        for k in 1..<perLogSignatures.count {
            if isCancelled() { return [] }
            uniqueSignatures.formIntersection(perLogSignatures[k])
        }
        uniqueSignatures.subtract(referenceSignatures)

        // 3. Emit every matching line from the first problem log, in order, with no
        //    de-duplication (mirrors checklog.py run without --reportonce).
        var result: [String] = []
        for entry in firstLogEntries where uniqueSignatures.contains(entry.sig) {
            result.append(entry.line)
        }
        return result
    }

    /// Number of lines a worker processes before reporting progress / checking
    /// cancellation, balancing overhead against responsiveness.
    nonisolated private static let chunkSize = 8192

    /// Splits `count` into `chunkSize`-line chunks so the work can be spread across
    /// cores by `DispatchQueue.concurrentPerform`.
    nonisolated private static func chunkCount(for count: Int) -> Int {
        (count + chunkSize - 1) / chunkSize
    }

    /// Computes the set of signatures for one log, dividing the lines into chunks
    /// processed concurrently across all CPU cores. Each worker builds a local set
    /// (no shared mutable state on the hot path) and the locals are merged at the end.
    nonisolated private static func signatureSet(
        for source: LogComparisonSource,
        isCancelled: @Sendable () -> Bool,
        progress: ScanProgress?
    ) -> Set<String> {
        let count = source.count
        guard count > 0 else { return [] }

        let chunks = chunkCount(for: count)
        let provider = source.provider
        let box = ChunkResults<Set<String>>(chunks: chunks)

        // Each iteration owns a disjoint line range, so the concurrent workers never
        // touch the same output slot.
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            if isCancelled() { return }
            let start = chunk * chunkSize
            let end = min(start + chunkSize, count)
            var local = Set<String>()
            for i in start..<end {
                local.insert(signature(for: provider.line(at: i)))
            }
            progress?.add(end - start)
            box.store(local, at: chunk)
        }

        var merged = Set<String>()
        for chunk in box.all() { merged.formUnion(chunk) }
        return merged
    }

    /// Computes the ordered `(line, signature)` entries for one log — used for the
    /// first problem log, whose lines are emitted in original order. The per-chunk
    /// work runs concurrently across cores; results are stitched back in chunk order.
    nonisolated private static func orderedEntries(
        for source: LogComparisonSource,
        isCancelled: @Sendable () -> Bool,
        progress: ScanProgress?
    ) -> [(line: String, sig: String)] {
        let count = source.count
        guard count > 0 else { return [] }

        let chunks = chunkCount(for: count)
        let provider = source.provider
        let box = ChunkResults<[(line: String, sig: String)]>(chunks: chunks)

        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            if isCancelled() { return }
            let start = chunk * chunkSize
            let end = min(start + chunkSize, count)
            var local: [(line: String, sig: String)] = []
            local.reserveCapacity(end - start)
            for i in start..<end {
                let line = provider.line(at: i)
                local.append((line, signature(for: line)))
            }
            progress?.add(end - start)
            box.store(local, at: chunk)
        }

        var result: [(line: String, sig: String)] = []
        result.reserveCapacity(count)
        for chunk in box.all() { result.append(contentsOf: chunk) }
        return result
    }
}

/// Thread-safe collector for the per-chunk outputs of a `concurrentPerform` scan.
/// Each chunk index is written exactly once by exactly one worker, and reads happen
/// only after the parallel loop has completed, so a single lock around the backing
/// store is ample.
nonisolated private final class ChunkResults<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element?]

    nonisolated init(chunks: Int) {
        storage = Array(repeating: nil, count: chunks)
    }

    nonisolated func store(_ element: Element, at index: Int) {
        lock.lock()
        storage[index] = element
        lock.unlock()
    }

    /// The stored chunk outputs in chunk order. Empty for any chunk skipped due to
    /// cancellation.
    nonisolated func all() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { $0 }
    }
}
