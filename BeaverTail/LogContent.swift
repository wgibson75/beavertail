//
//  LogContent.swift
//  BeaverTail
//

import Foundation
import os

/// A compiled matcher used to test log lines. For plain-substring patterns we use
/// a fast byte-level search over the memory map (no String allocation, no
/// NSRegularExpression); for true regex patterns we fall back to NSRegularExpression
/// — but first reject the vast majority of lines with a cheap byte "pre-filter"
/// (a literal that every match MUST contain), so the regex engine only runs on the
/// few lines that could actually match. This is the key trick fast tools like
/// Klogg / ripgrep use.
enum LineMatcher {
    case literalSensitive(needle: [UInt8])
    case literalInsensitiveASCII(needleLower: [UInt8])
    /// Pure alternation of literals (e.g. `a|bb|ccc`) — matched in a single byte
    /// pass without any regex engine.
    case multiLiteralSensitive(needles: [[UInt8]])
    case multiLiteralInsensitiveASCII(needles: [[UInt8]])
    /// `prefilters` is the list of required literals (one per alternation branch);
    /// a line can only match if it contains AT LEAST ONE of them. Empty means no
    /// pre-filter could be derived and the regex must run on every line.
    case regex(NSRegularExpression, prefilters: [[UInt8]], caseInsensitive: Bool)

    /// The set of characters that make a pattern a real regular expression.
    private static let regexMeta = Set("\\^$.|?*+()[]{}")

    static func make(pattern: String, caseInsensitive: Bool) -> LineMatcher? {
        guard !pattern.isEmpty else { return nil }

        // 1. Pure single literal (no regex metacharacters at all).
        if !pattern.contains(where: { regexMeta.contains($0) }) {
            let needle = Array(pattern.utf8)
            let asciiOnly = needle.allSatisfy { $0 < 0x80 }
            if !caseInsensitive {
                return .literalSensitive(needle: needle)
            } else if asciiOnly {
                return .literalInsensitiveASCII(needleLower: needle.map { asciiLowered($0) })
            }
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            return (try? NSRegularExpression(pattern: escaped, options: [.caseInsensitive]))
                .map { .regex($0, prefilters: [], caseInsensitive: false) }
        }

        // 2. Pure alternation of literals (`a|bb|ccc`). ICU is fine at this but a
        //    single-pass multi-literal scan with no regex is faster, and avoids the
        //    redundant "pre-filter then regex" double work.
        let branches = splitTopLevelAlternation(pattern)
        if branches.count >= 2,
           branches.allSatisfy({ !$0.isEmpty && !$0.contains(where: { regexMeta.contains($0) }) }) {
            if !caseInsensitive {
                return .multiLiteralSensitive(needles: branches.map { Array($0.utf8) })
            } else if branches.allSatisfy({ $0.allSatisfy { $0.isASCII } }) {
                return .multiLiteralInsensitiveASCII(needles: branches.map { Array($0.utf8).map { asciiLowered($0) } })
            }
            // non-ASCII case-insensitive → fall through to regex
        }

        // 3. General regex, with a required-literal pre-filter where possible.
        let opts: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let rx = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        // Derive a required-literal pre-filter (one literal per alternation branch).
        var prefilters: [[UInt8]] = []
        let parsedLits = requiredLiterals(in: pattern)
        if let lits = parsedLits, lits.allSatisfy({ $0.allSatisfy { $0.isASCII } }) {
            prefilters = lits.map { lit -> [UInt8] in
                let bytes = Array(lit.utf8)
                return caseInsensitive ? bytes.map { asciiLowered($0) } : bytes
            }
        }

        // If we extracted pre-filters but didn't identify it as a pure literal alternation,
        // we can still skip the regex entirely if the original pattern is exactly equivalent
        // to joining the extracted pre-filters with '|'.
        if !prefilters.isEmpty, let lits = parsedLits {
            let joinedLits = lits.joined(separator: "|")
            if joinedLits == pattern {
                if !caseInsensitive {
                    return .multiLiteralSensitive(needles: prefilters)
                } else {
                    return .multiLiteralInsensitiveASCII(needles: prefilters)
                }
            }
        }

        return .regex(rx, prefilters: prefilters, caseInsensitive: caseInsensitive)
    }

    private static func asciiLowered(_ b: UInt8) -> UInt8 {
        (b >= 65 && b <= 90) ? b + 32 : b
    }

    /// Splits `pattern` into top-level alternation branches and extracts a required
    /// literal (≥3 ASCII chars) from each. Returns nil unless EVERY branch yields a
    /// literal (otherwise a line could match via a branch with no guaranteed text).
    static func requiredLiterals(in pattern: String) -> [String]? {
        let branches = splitTopLevelAlternation(pattern)
        var result: [String] = []
        for branch in branches {
            // For alternation, even short literals are better than no pre-filter,
            // so we don't enforce the >= 3 length limit here if it's the whole branch.
            guard let lit = requiredLiteral(in: branch) else { return nil }
            result.append(lit)
        }
        return result.isEmpty ? nil : result
    }

    /// Splits on `|` that sit at paren/bracket depth 0 (respecting escapes).
    private static func splitTopLevelAlternation(_ pattern: String) -> [String] {
        var branches: [String] = []
        var current = ""
        var depth = 0
        var inClass = false
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\", i + 1 < chars.count {
                current.append(ch); current.append(chars[i + 1]); i += 2; continue
            }
            switch ch {
            case "[": inClass = true; current.append(ch)
            case "]": inClass = false; current.append(ch)
            case "(" where !inClass: depth += 1; current.append(ch)
            case ")" where !inClass: depth -= 1; current.append(ch)
            case "|" where !inClass && depth == 0:
                branches.append(current); current = ""
            default:
                current.append(ch)
            }
            i += 1
        }
        branches.append(current)
        return branches
    }

    /// Extracts the longest literal substring that EVERY match of a single
    /// (alternation-free) branch must contain. Conservative; returns nil if none
    /// of length ≥ 3 exists or the branch contains nested alternation.
    static func requiredLiteral(in pattern: String) -> String? {
        let chars = Array(pattern)
        var k = 0
        while k < chars.count {
            if chars[k] == "\\" { k += 2; continue }
            if chars[k] == "|" { return nil }
            k += 1
        }

        var best = ""
        var cur = ""
        func flush() { if cur.count > best.count { best = cur }; cur = "" }

        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "\\":
                if i + 1 < chars.count {
                    let next = chars[i + 1]
                    // If it's escaping a regex meta character, we can include the literal character itself.
                    if regexMeta.contains(next) {
                        cur.append(next)
                    } else {
                        flush()
                    }
                }
                i += 2
            case "[":
                flush(); i += 1
                if i < chars.count, chars[i] == "^" { i += 1 }
                if i < chars.count, chars[i] == "]" { i += 1 }
                while i < chars.count, chars[i] != "]" { i += (chars[i] == "\\") ? 2 : 1 }
                if i < chars.count { i += 1 }
            case "(", ")", ".", "^", "$":
                flush(); i += 1
            case "?", "*":
                if !cur.isEmpty { cur.removeLast() }
                flush(); i += 1
            case "+":
                flush(); i += 1
            case "{":
                var j = i + 1
                var content = ""
                while j < chars.count, chars[j] != "}" { content.append(chars[j]); j += 1 }
                if j < chars.count {
                    let minStr = content.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? content
                    let minVal = Int(minStr.trimmingCharacters(in: .whitespaces)) ?? 0
                    if minVal == 0, !cur.isEmpty { cur.removeLast() }
                    flush()
                    i = j + 1
                } else {
                    cur.append(ch); i += 1
                }
            default:
                cur.append(ch); i += 1
            }
        }
        flush()
        // If the entire branch is a literal, accept it even if short.
        if best.count >= 3 || best.count == pattern.count { return best }
        return nil
    }
}

/// Returns true if `[hay, hay+len)` contains the needle `[needle, needle+nlen)`,
/// comparing ASCII letters case-insensitively. Pointer-based, no allocation.
@inline(__always)
    nonisolated private func asciiInsensitiveContainsPtr(_ hay: UnsafePointer<UInt8>, _ len: Int, _ needle: UnsafePointer<UInt8>?, _ nlen: Int) -> Bool {
    if nlen == 0 { return true }
    guard let needle, len >= nlen else { return false }
    let cFirst = needle[0]
    var cFirstAlt = cFirst
    if cFirst >= 97 && cFirst <= 122 { cFirstAlt = cFirst - 32 } else if cFirst >= 65 && cFirst <= 90 { cFirstAlt = cFirst + 32 }

    let last = len - nlen
    var i = 0
    while i <= last {
        let ch = hay[i]
        if ch == cFirst || ch == cFirstAlt {
            var j = 1
            while j < nlen {
                var c = hay[i + j]
                if c >= 65 && c <= 90 { c += 32 }
                if c != needle[j] { break }
                j += 1
            }
            if j == nlen { return true }
        }
        i += 1
    }
    return false
}

/// Thread-safe progress counter. Worker threads bump `current` cheaply; the UI
/// reads `fraction` from a timer on the main thread. This decouples progress
/// reporting from the scan so the bar stays smooth even while every core is busy.
final class ScanProgress: @unchecked Sendable {
    private var _current: Int = 0
    // os_unfair_lock (via OSAllocatedUnfairLock) donates the waiter's priority to the
    // lock holder, avoiding priority inversions when the user-interactive main thread
    // polls `fraction` while a lower-QoS scan thread is calling `add`.
    private let lock = OSAllocatedUnfairLock()
    let total: Int
    init(total: Int) { self.total = max(total, 1) }
    func add(_ n: Int) {
        lock.lock(); _current += n; lock.unlock()
    }
    var fraction: Double {
        lock.lock(); let c = _current; lock.unlock()
        return min(1.0, Double(c) / Double(total))
    }
}

/// Random-access provider of log lines by index.
protocol LineProvider: Sendable {
    var count: Int { get }
    func line(at index: Int) -> String
    /// Maps a display row back to its original line number in the source file.
    /// For unfiltered providers this is the identity; for filtered providers it
    /// returns the original index of the matched line.
    func originalIndex(at index: Int) -> Int
}

extension LineProvider {
    nonisolated func originalIndex(at index: Int) -> Int { index }
}

/// Trivial provider backed by an in-memory array — used for placeholder/status
/// text (e.g. "Loading…") and error messages.
struct ArrayLineProvider: LineProvider, Sendable {
    let lines: [String]
    nonisolated var count: Int { lines.count }
    nonisolated func line(at index: Int) -> String {
        (index >= 0 && index < lines.count) ? lines[index] : ""
    }
}

/// Provider for filtered results: a list of matching original line indices,
/// decoded on demand from the underlying memory-mapped content. This avoids
/// materialising millions of copied strings for large match sets.
struct FilteredLineProvider: LineProvider, @unchecked Sendable {
    let content: LogContent
    let indices: [Int]

    init(content: LogContent, indices: [Int]) {
        self.content = content
        self.indices = indices
    }

    var count: Int { indices.count }

    func line(at index: Int) -> String {
        guard index >= 0, index < indices.count else { return "" }
        return content.line(at: indices[index])
    }

    func originalIndex(at index: Int) -> Int {
        (index >= 0 && index < indices.count) ? indices[index] : index
    }
}

/// Memory-mapped log file with a lazily-decoded line index.
final class LogContent: LineProvider, @unchecked Sendable {
    private let data: Data
    /// Byte offset of the first character of each indexed line. Populated
    /// incrementally by `buildIndex` (append-only) so lines can be displayed as
    /// they are discovered; all access is guarded by `lock`.
    nonisolated(unsafe) private var lineStarts: ContiguousArray<Int>
    private let totalBytes: Int
    // os_unfair_lock (via OSAllocatedUnfairLock) supports priority inheritance, so the
    // user-interactive main thread reading `count` / `line(at:)` during rendering
    // donates its priority to any lower-QoS scan thread holding the lock — avoiding the
    // priority inversion an NSLock (pthread mutex) would cause.
    private let lock = OSAllocatedUnfairLock()

    /// True once the full on-disk index has been built. While indexing is still in
    /// progress the final indexed offset marks the start of a line whose end isn't
    /// known yet, so that trailing line is hidden from `count` — this guarantees we
    /// never decode a partially-scanned line that would otherwise span to EOF.
    /// Guarded by `lock`.
    nonisolated(unsafe) private var scanComplete: Bool

    /// Lines appended at runtime by live-tailing (not part of the mmap index).
    nonisolated(unsafe) private var appended: [String] = []

    /// Number of fully-terminated indexed lines currently visible (must be called
    /// with `lock` held).
    nonisolated private var visibleIndexedCountLocked: Int {
        scanComplete ? lineStarts.count : Swift.max(0, lineStarts.count - 1)
    }

    /// Number of lines that came from the on-disk index (excludes live-tail appends).
    nonisolated var indexedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return visibleIndexedCountLocked
    }
    nonisolated var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return visibleIndexedCountLocked + appended.count
    }

    nonisolated init(data: Data, lineStarts: ContiguousArray<Int>, totalBytes: Int, scanComplete: Bool = true) {
        self.data = data
        self.lineStarts = lineStarts
        self.totalBytes = totalBytes
        self.scanComplete = scanComplete
    }

    /// Appends live-tailed lines that arrived after the file was indexed.
    nonisolated func appendLines(_ lines: [String]) {
        lock.lock()
        appended.append(contentsOf: lines)
        lock.unlock()
    }

    nonisolated func line(at index: Int) -> String {
        guard index >= 0 else { return "" }
        lock.lock()
        let indexed = lineStarts.count
        // Live-tail overflow region
        if index >= indexed {
            let a = index - indexed
            let result = (a >= 0 && a < appended.count) ? appended[a] : ""
            lock.unlock()
            return result
        }
        let start = lineStarts[index]
        let hasNext = index + 1 < indexed
        let nextStart = hasNext ? lineStarts[index + 1] : 0
        let complete = scanComplete
        lock.unlock()

        // The next line's start is one byte past this line's newline, so this
        // line's content ends at (nextStart - 1). The final indexed line runs to
        // EOF, but only once scanning is complete — while indexing is in progress a
        // trailing, not-yet-terminated line is hidden by `count`, so we defensively
        // return empty rather than decode all the way to EOF.
        let rawEnd: Int
        if hasNext {
            rawEnd = nextStart - 1
        } else if complete {
            rawEnd = totalBytes
        } else {
            return ""
        }
        let end = max(start, rawEnd)
        return data.withUnsafeBytes { raw -> String in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return "" }
            var e = end
            if e > start, base[e - 1] == 0x0D { e -= 1 } // strip trailing CR (CRLF)
            return String(decoding: UnsafeBufferPointer(start: base + start, count: e - start), as: UTF8.self)
        }
    }

    // MARK: - Fast parallel incremental index build

    /// Memory-maps `url` without scanning it. The returned content has an empty
    /// index (and reports `scanComplete == false`); call `buildIndex` to populate
    /// it. The file is never read into memory in its entirety — only the OS page
    /// cache backs the mapping and pages are faulted in on demand.
    nonisolated static func mappedEmpty(from url: URL) throws -> LogContent {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let total = data.count
        if total > 0 {
            // Hint the kernel that we'll read the whole mapping sequentially so it
            // does large readahead instead of slow 4KB demand faults — a big win for
            // the full scans done during indexing and filtering.
            data.withUnsafeBytes { raw in
                if let p = raw.baseAddress {
                    madvise(UnsafeMutableRawPointer(mutating: p), raw.count, MADV_SEQUENTIAL)
                }
            }
        }
        return LogContent(data: data, lineStarts: [], totalBytes: total, scanComplete: false)
    }

    /// Backwards-compatible one-shot build: maps and fully indexes `url` before
    /// returning. Used by callers that don't need progressive display.
    nonisolated static func build(from url: URL, progress: ScanProgress? = nil) throws -> LogContent {
        let content = try mappedEmpty(from: url)
        content.buildIndex(progress: progress, onSegment: { _ in })
        return content
    }

    /// Scans the mapped data for line starts, appending them to the index in file
    /// order. `onSegment` is invoked (on the calling thread) after each segment has
    /// been indexed, allowing the caller to publish the growing index to the UI so
    /// lines appear progressively instead of only after the whole file is scanned.
    ///
    /// The scan walks the file sequentially in segments (so the earliest lines
    /// become visible first), while each individual segment is scanned in parallel
    /// across all cores — preserving the throughput of the original whole-file
    /// parallel scan. Only byte offsets are ever stored; the file itself is never
    /// materialised in memory.
    nonisolated func buildIndex(progress: ScanProgress? = nil, onSegment: (LogContent) -> Void) {
        let total = totalBytes
        guard total > 0 else {
            lock.lock(); scanComplete = true; lock.unlock()
            onSegment(self)
            return
        }
        let newline: UInt8 = 0x0A
        let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

        data.withUnsafeBytes { rawBuffer in
            nonisolated(unsafe) let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress!

            // The first line always starts at offset 0.
            appendIndexOffsets([0])

            let ctx = IndexScanContext(
                base: base, total: total, newline: newline,
                coreCount: coreCount, progress: progress
            )
            var segStart = 0
            // Start with a small first segment so the first screenful of lines is
            // indexed and shown almost immediately, then ramp the segment size up to
            // keep per-segment overhead negligible for the rest of a huge file.
            var segSize = 4 * 1024 * 1024
            let maxSegSize = 256 * 1024 * 1024

            while segStart < total {
                let segEnd = min(segStart + segSize, total)
                let offsets = Self.scanSegment(ctx, from: segStart, to: segEnd)
                if !offsets.isEmpty {
                    appendIndexOffsets(offsets)
                }
                onSegment(self)
                segStart = segEnd
                segSize = min(segSize * 2, maxSegSize)
            }

            lock.lock(); scanComplete = true; lock.unlock()
            onSegment(self)
        }
    }

    /// Fixed context shared by every segment scan during an index build.
    nonisolated private struct IndexScanContext {
        let base: UnsafePointer<UInt8>
        let total: Int
        let newline: UInt8
        let coreCount: Int
        let progress: ScanProgress?
    }

    /// Scans `[from, to)` for newlines in parallel, returning the resulting line
    /// start offsets (each one byte past a newline) in ascending order. Any offset
    /// at or beyond `total` (a trailing EOF newline) is omitted so no phantom empty
    /// final line is produced.
    nonisolated private static func scanSegment(
        _ ctx: IndexScanContext, from: Int, to: Int
    ) -> [Int] {
        nonisolated(unsafe) let base = ctx.base
        let total = ctx.total
        let newline = ctx.newline
        let coreCount = ctx.coreCount
        let progress = ctx.progress
        let length = to - from
        guard length > 0 else { return [] }

        // Split the segment across cores. Cap the number of sub-chunks so tiny early
        // segments don't spawn excessive parallel work.
        let targetChunks = max(1, min(coreCount, length / (256 * 1024) + 1))
        let approxChunk = max(1, length / targetChunks)

        var ranges: [(start: Int, end: Int)] = []
        var s = from
        while s < to {
            let e = min(s + approxChunk, to)
            ranges.append((s, e))
            s = e
        }
        let chunkCount = ranges.count
        var partials = [[Int]](repeating: [], count: chunkCount)

        partials.withUnsafeMutableBufferPointer { outParam in
            nonisolated(unsafe) let out = outParam
            DispatchQueue.concurrentPerform(iterations: chunkCount) { i in
                let (cs, ce) = ranges[i]
                var local: [Int] = []
                local.reserveCapacity((ce - cs) / 100)

                var ptr: UnsafeRawPointer = UnsafeRawPointer(base + cs)
                let endPtr: UnsafeRawPointer = UnsafeRawPointer(base + ce)

                var sinceReport = 0
                let reportChunk = max(100_000, (ce - cs) / 20)

                while ptr < endPtr, let found = memchr(ptr, Int32(newline), ptr.distance(to: endPtr)) {
                    let foundPtr = found.assumingMemoryBound(to: UInt8.self)
                    let dist = base.distance(to: foundPtr)
                    if dist + 1 < total { local.append(dist + 1) }
                    let advanced = ptr.distance(to: UnsafeRawPointer(foundPtr + 1))
                    sinceReport += advanced
                    ptr = UnsafeRawPointer(foundPtr + 1)

                    if sinceReport >= reportChunk {
                        progress?.add(sinceReport)
                        sinceReport = 0
                    }
                }

                out[i] = local
                let left = ptr.distance(to: endPtr)
                if left > 0 { sinceReport += left }
                if sinceReport > 0 { progress?.add(sinceReport) }
            }
        }

        var totalNewlines = 0
        for c in partials { totalNewlines += c.count }
        var result: [Int] = []
        result.reserveCapacity(totalNewlines)
        for c in partials { result.append(contentsOf: c) }
        return result
    }

    /// Appends freshly-scanned line-start offsets to the index under lock. The
    /// index is a single Int per line (~8 bytes); it grows by the standard array
    /// doubling policy, so its peak footprint matches the original whole-file build
    /// and no file contents are ever copied.
    nonisolated private func appendIndexOffsets(_ offsets: [Int]) {
        lock.lock()
        lineStarts.append(contentsOf: offsets)
        lock.unlock()
    }

    /// Point-in-time snapshot of the indexed line starts for the parallel bulk scanners.
    private struct IndexSnapshot {
        let starts: ContiguousArray<Int>
        let indexed: Int
        let scanCount: Int
    }

    /// A stable, point-in-time snapshot of the indexed line starts for the parallel
    /// bulk scanners. Because the index is append-only, the returned copy-on-write
    /// buffer is never mutated after this call (a later append copies to a fresh
    /// buffer), so raw pointers into it stay valid for the scan's duration even if
    /// indexing is still in progress on another thread. `scanCount` excludes the
    /// final, not-yet-terminated line while indexing is still running.
    nonisolated private func indexSnapshot() -> IndexSnapshot {
        lock.lock()
        let snapshot = lineStarts
        let complete = scanComplete
        lock.unlock()
        let indexed = snapshot.count
        let scanCount = complete ? indexed : Swift.max(0, indexed - 1)
        return IndexSnapshot(starts: snapshot, indexed: indexed, scanCount: scanCount)
    }

    // MARK: - Filter scan helpers

    /// Scan mode used by ScanParams.
    private enum ScanMode: Sendable {
        case litSensitive, litInsensitive
        case multiLitSensitive, multiLitInsensitive
        case regexOnly, regexPreSensitive, regexPreInsensitive
    }

    /// Decoded scan parameters built once before the parallel scan.
    private struct ScanParams {
        let mode: ScanMode
        let regex: NSRegularExpression?
        let blob: [UInt8]
        let offsets: [Int]
        let lengths: [Int]
        let firstByteTable: [Bool]   // 256-entry acceptance table
    }

    nonisolated private static func buildScanParams(from matcher: LineMatcher) -> ScanParams {
        var blob: [UInt8] = []
        var offs: [Int] = []
        var lens: [Int] = []
        func addNeedle(_ needle: [UInt8]) {
            offs.append(blob.count); lens.append(needle.count); blob.append(contentsOf: needle)
        }
        let mode: ScanMode
        let theRegex: NSRegularExpression?
        switch matcher {
        case .literalSensitive(let needle):
            mode = .litSensitive; addNeedle(needle); theRegex = nil
        case .literalInsensitiveASCII(let needle):
            mode = .litInsensitive; addNeedle(needle); theRegex = nil
        case .multiLiteralSensitive(let needles):
            mode = .multiLitSensitive; for needle in needles { addNeedle(needle) }; theRegex = nil
        case .multiLiteralInsensitiveASCII(let needles):
            mode = .multiLitInsensitive; for needle in needles { addNeedle(needle) }; theRegex = nil
        case .regex(let regex, let preFilters, let caseInsensitive):
            theRegex = regex
            for preFilter in preFilters { addNeedle(preFilter) }
            mode = preFilters.isEmpty ? .regexOnly
                : (caseInsensitive ? .regexPreInsensitive : .regexPreSensitive)
        }
        let needleCount = offs.count
        let isCaseInsensitive: Bool
        switch mode {
        case .litInsensitive, .multiLitInsensitive, .regexPreInsensitive: isCaseInsensitive = true
        default: isCaseInsensitive = false
        }
        var firstByteTable = [Bool](repeating: false, count: 256)
        for idx in 0 ..< needleCount where lens[idx] > 0 {
            let byte = blob[offs[idx]]
            firstByteTable[Int(byte)] = true
            if isCaseInsensitive {
                if byte >= 97 && byte <= 122 { firstByteTable[Int(byte - 32)] = true }
                if byte >= 65 && byte <= 90 { firstByteTable[Int(byte + 32)] = true }
            }
        }
        return ScanParams(
            mode: mode, regex: theRegex,
            blob: blob, offsets: offs, lengths: lens,
            firstByteTable: firstByteTable
        )
    }

    // swiftlint:disable:next function_parameter_count
    private static func lineMatchesScan(
        base: UnsafePointer<UInt8>,
        start: Int, len: Int,
        params: ScanParams,
        fbBase: UnsafePointer<Bool>,
        blobBase: UnsafePointer<UInt8>?,
        cachedLineStr: inout String?,
        localRegex: NSRegularExpression?
    ) -> Bool {
        let needleCount = params.offsets.count
        let offsLet = params.offsets
        let lensLet = params.lengths
        switch params.mode {
        case .litSensitive:
            let nl = lensLet[0]
            return nl <= len && memmem(base + start, len, blobBase, nl) != nil
        case .litInsensitive:
            return asciiInsensitiveContainsPtr(base + start, len, blobBase, lensLet[0])
        case .multiLitSensitive:
            var pos = 0
            while pos < len {
                if fbBase[Int(base[start + pos])] {
                    var ki = 0
                    while ki < needleCount {
                        let nl = lensLet[ki]
                        if nl <= len - pos {
                            let no = offsLet[ki]
                            var ji = 0
                            while ji < nl {
                                if base[start + pos + ji] != blobBase![no + ji] { break }
                                ji += 1
                            }
                            if ji == nl { return true }
                        }
                        ki += 1
                    }
                }
                pos += 1
            }
            return false
        case .multiLitInsensitive:
            var pos = 0
            while pos < len {
                if fbBase[Int(base[start + pos])] {
                    var ki = 0
                    while ki < needleCount {
                        let nl = lensLet[ki]
                        if nl <= len - pos {
                            let no = offsLet[ki]
                            var ji = 0
                            while ji < nl {
                                var ch = base[start + pos + ji]
                                if ch >= 65 && ch <= 90 { ch += 32 }
                                if ch != blobBase![no + ji] { break }
                                ji += 1
                            }
                            if ji == nl { return true }
                        }
                        ki += 1
                    }
                }
                pos += 1
            }
            return false
        case .regexOnly:
            if cachedLineStr == nil {
                cachedLineStr = String(decoding: UnsafeBufferPointer(start: base + start, count: len), as: UTF8.self)
            }
            let lineStr = cachedLineStr!
            let range = NSRange(location: 0, length: lineStr.utf16.count)
            return localRegex!.firstMatch(in: lineStr, options: [], range: range) != nil
        case .regexPreSensitive:
            var hit = false
            var ki = 0
            while ki < needleCount {
                let nl = lensLet[ki]
                if nl <= len, memmem(base + start, len, blobBase! + offsLet[ki], nl) != nil { hit = true; break }
                ki += 1
            }
            guard hit else { return false }
            if cachedLineStr == nil {
                cachedLineStr = String(decoding: UnsafeBufferPointer(start: base + start, count: len), as: UTF8.self)
            }
            let lineStr = cachedLineStr!
            let range = NSRange(location: 0, length: lineStr.utf16.count)
            return localRegex!.firstMatch(in: lineStr, options: [], range: range) != nil
        case .regexPreInsensitive:
            var hit = false
            var ki = 0
            while ki < needleCount {
                if asciiInsensitiveContainsPtr(base + start, len, blobBase! + offsLet[ki], lensLet[ki]) {
                    hit = true; break
                }
                ki += 1
            }
            guard hit else { return false }
            if cachedLineStr == nil {
                cachedLineStr = String(decoding: UnsafeBufferPointer(start: base + start, count: len), as: UTF8.self)
            }
            let lineStr = cachedLineStr!
            let range = NSRange(location: 0, length: lineStr.utf16.count)
            return localRegex!.firstMatch(in: lineStr, options: [], range: range) != nil
        }
    }

    /// Parallel scan returning indices of lines that match `matcher`.
    /// Does not allocate a String per line — searches raw memory-mapped bytes.
    /// Progress is reported into `progress` (polled by the UI timer).
    func filterMatches(matcher: LineMatcher, progress: ScanProgress, onUpdate: @escaping ([Int]) -> Void) {
        // Take a stable snapshot so this scan is safe even if the index is still
        // being built on another thread. `indexed` bounds valid offsets for line-end
        // computation; `scanCount` excludes any not-yet-terminated trailing line.
        let snap = indexSnapshot()
        let starts = snap.starts
        let indexed = snap.indexed
        let scanCount = snap.scanCount
        guard scanCount > 0 || !appended.isEmpty else { onUpdate([]); return }

        let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let targetChunks = min(coreCount * 8, 128)
        let chunkSize = max(1, (scanCount + targetChunks - 1) / targetChunks)
        var ranges: [(start: Int, end: Int)] = []
        var rangeStart = 0
        while rangeStart < scanCount {
            let rangeEnd = min(rangeStart + chunkSize, scanCount)
            ranges.append((rangeStart, rangeEnd))
            rangeStart = rangeEnd
        }
        let chunkCount = ranges.count
        var partials = [[Int]](repeating: [], count: max(chunkCount, 1))
        let params = Self.buildScanParams(from: matcher)
        let outLock = NSLock()
        var nextChunkToEmit = 0
        var emittedSoFar: [Int] = []
        var completeChunks: [Int: [Int]] = [:]

        var lastEmitTime = DispatchTime.now()
        let performUpdates = { (snapshot: [Int], force: Bool) in
            outLock.lock()
            let now = DispatchTime.now()
            let diff = now.uptimeNanoseconds - lastEmitTime.uptimeNanoseconds
            let shouldEmit = force || diff > 150_000_000
            if shouldEmit { lastEmitTime = now }
            outLock.unlock()
            if shouldEmit { onUpdate(snapshot) }
        }

        if chunkCount > 0 {
            params.firstByteTable.withUnsafeBufferPointer { fbPtr in
                let fbBase = fbPtr.baseAddress!
                params.blob.withUnsafeBufferPointer { blobPtr in
                    let blobBase = blobPtr.baseAddress
                    data.withUnsafeBytes { rawBuffer in
                        nonisolated(unsafe) let base = UnsafePointer(
                            rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                        )
                        let total = totalBytes
                        nonisolated(unsafe) let nBlob = blobBase

                        starts.withUnsafeBufferPointer { startsBuffer in
                            nonisolated(unsafe) let startsPtr = startsBuffer.baseAddress!
                            partials.withUnsafeMutableBufferPointer { outParam in
                                nonisolated(unsafe) let out = outParam
                                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIdx in
                                    let localRx: NSRegularExpression? = params.regex.flatMap {
                                        try? NSRegularExpression(pattern: $0.pattern, options: $0.options)
                                    }
                                    let (cs, ce) = ranges[chunkIdx]
                                    var matches: [Int] = []
                                    var startIdx = cs
                                    while startIdx < ce {
                                        autoreleasepool {
                                            let endIdx = min(startIdx + 2048, ce)
                                            var sinceReport = 0
                                            var cachedLineStr: String?
                                            for lineIdx in startIdx ..< endIdx {
                                                let lineStart = startsPtr[lineIdx]
                                                let rawEnd = (lineIdx + 1 < indexed)
                                                    ? startsPtr[lineIdx + 1] - 1 : total
                                                var lineEnd = max(lineStart, rawEnd)
                                                if lineEnd > lineStart, base[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                                                let lineLen = lineEnd - lineStart
                                                cachedLineStr = nil
                                                if Self.lineMatchesScan(
                                                    base: base, start: lineStart, len: lineLen,
                                                    params: params, fbBase: fbBase, blobBase: nBlob,
                                                    cachedLineStr: &cachedLineStr,
                                                    localRegex: localRx
                                                ) { matches.append(lineIdx) }
                                                sinceReport += 1
                                            }
                                            if sinceReport > 0 { progress.add(sinceReport) }
                                            startIdx = endIdx
                                        }
                                    }
                                    out[chunkIdx] = matches
                                    outLock.lock()
                                    completeChunks[chunkIdx] = matches
                                    var didEmit = false
                                    while let ready = completeChunks.removeValue(forKey: nextChunkToEmit) {
                                        emittedSoFar.append(contentsOf: ready)
                                        nextChunkToEmit += 1
                                        didEmit = true
                                    }
                                    let snapshot = emittedSoFar
                                    outLock.unlock()
                                    if didEmit { performUpdates(snapshot, false) }
                                }
                            }
                        }
                    }
                }
            }
        }

        outLock.lock()
        var finalMatches: [Int] = emittedSoFar
        outLock.unlock()
        if !appended.isEmpty {
            for (offset, line) in appended.enumerated()
            where lineMatches(line, matcher: matcher) {
                finalMatches.append(indexed + offset)
            }
        }
        performUpdates(finalMatches, true)
    }

    /// Optimized extraction of all lines matching multiple matchers in a single parallel pass.
    nonisolated func extractAllMatches(matchers: [LineMatcher], onUpdate: @escaping ([[Int]], Bool) -> Void) {
        // Stable snapshot: safe even if the index is still being built (see filterMatches).
        let snap = indexSnapshot()
        let starts = snap.starts
        let indexed = snap.indexed
        let scanCount = snap.scanCount
        guard scanCount > 0 || !appended.isEmpty, !matchers.isEmpty else { onUpdate(Array(repeating: [], count: matchers.count), true); return }

        let paramsList = matchers.map { Self.buildScanParams(from: $0) }
        var allBlobs: [UInt8] = []
        var allFbs: [Bool] = []
        var offsets = [(blobOff: Int, fbOff: Int)]()

        for p in paramsList {
            offsets.append((blobOff: allBlobs.count, fbOff: allFbs.count))
            allBlobs.append(contentsOf: p.blob)
            allFbs.append(contentsOf: p.firstByteTable)
        }

        let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let targetChunks = min(coreCount * 8, 128)
        let chunkSize = max(1, (scanCount + targetChunks - 1) / targetChunks)
        var ranges: [(start: Int, end: Int)] = []
        var rangeStart = 0
        while rangeStart < scanCount {
            let rangeEnd = min(rangeStart + chunkSize, scanCount)
            ranges.append((rangeStart, rangeEnd))
            rangeStart = rangeEnd
        }
        let chunkCount = ranges.count

        let outLock = NSLock()
        var nextChunkToEmit = 0
        var emittedSoFar = [[Int]](repeating: [], count: matchers.count)
        var completeChunks: [Int: [[Int]]] = [:]

        var lastEmitTime = DispatchTime.now()

        let performUpdates = { (snapshot: [[Int]], force: Bool) in
            outLock.lock()
            let now = DispatchTime.now()
            let diff = now.uptimeNanoseconds - lastEmitTime.uptimeNanoseconds
            let shouldEmit = force || diff > 150_000_000
            if shouldEmit { lastEmitTime = now }
            outLock.unlock()

            if shouldEmit {
                onUpdate(snapshot, force)
            }
        }

        if chunkCount > 0 {
            allFbs.withUnsafeBufferPointer { fbPtr in
                let fbBase = fbPtr.baseAddress!
                allBlobs.withUnsafeBufferPointer { blobPtr in
                    let blobBase = blobPtr.baseAddress
                    data.withUnsafeBytes { rawBuffer in
                        nonisolated(unsafe) let base = UnsafePointer(rawBuffer.bindMemory(to: UInt8.self).baseAddress!)
                        let total = totalBytes
                        nonisolated(unsafe) let nBlob = blobBase

                        nonisolated(unsafe) let nFbs = fbBase

                        starts.withUnsafeBufferPointer { startsBuffer in
                            nonisolated(unsafe) let startsPtr = startsBuffer.baseAddress!
                            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIdx in
                                let localRegexes: [NSRegularExpression?] = paramsList.map { p in
                                    p.regex.flatMap { try? NSRegularExpression(pattern: $0.pattern, options: $0.options) }
                                }
                                let (cs, ce) = ranges[chunkIdx]
                                var chunkMatches = [[Int]](repeating: [], count: paramsList.count)
                                var startIdx = cs
                                while startIdx < ce {
                                    if Task.isCancelled { return }
                                    autoreleasepool {
                                        let endIdx = min(startIdx + 2048, ce)
                                        var cachedLineStr: String?
                                        for lineIdx in startIdx ..< endIdx {
                                            if Task.isCancelled { return }
                                            let lineStart = startsPtr[lineIdx]
                                            // Bounds-checked line length. `startsPtr[lineIdx + 1]`
                                            // must only be read when the next offset is actually
                                            // present in the snapshot (`lineIdx + 1 < indexed`);
                                            // for the final indexed line clamp to `total`. Reading
                                            // one element past the snapshot buffer here yielded a
                                            // garbage length and an out-of-bounds read into the
                                            // memory-mapped file (EXC_BAD_ACCESS).
                                            let rawEnd = (lineIdx + 1 < indexed) ? startsPtr[lineIdx + 1] - 1 : total
                                            var lineEnd = max(lineStart, rawEnd)
                                            if lineEnd > lineStart, base[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                                            let lineLen = lineEnd - lineStart
                                            cachedLineStr = nil
                                            for mIdx in 0..<paramsList.count {
                                                let p = paramsList[mIdx]
                                                let off = offsets[mIdx]
                                                if Self.lineMatchesScan(
                                                    base: base, start: lineStart, len: lineLen,
                                                    params: p, fbBase: nFbs + off.fbOff, blobBase: nBlob != nil ? nBlob! + off.blobOff : nil,
                                                    cachedLineStr: &cachedLineStr,
                                                    localRegex: localRegexes[mIdx]
                                                ) {
                                                    chunkMatches[mIdx].append(lineIdx)
                                                }
                                            }
                                        }
                                        startIdx = endIdx
                                    }
                                }

                                outLock.lock()
                                completeChunks[chunkIdx] = chunkMatches
                                var didEmit = false
                                while let ready = completeChunks.removeValue(forKey: nextChunkToEmit) {
                                    for mIdx in 0..<matchers.count {
                                        emittedSoFar[mIdx].append(contentsOf: ready[mIdx])
                                    }
                                    nextChunkToEmit += 1
                                    didEmit = true
                                }
                                let snapshot = emittedSoFar
                                outLock.unlock()

                                if didEmit {
                                    performUpdates(snapshot, false)
                                }
                            }
                        }
                    }
                }
            }
        }

        outLock.lock()
        var finalMatches = emittedSoFar
        outLock.unlock()

        if !appended.isEmpty {
            for (offset, line) in appended.enumerated() {
                for mIdx in 0..<matchers.count {
                    if lineMatches(line, matcher: matchers[mIdx]) {
                        finalMatches[mIdx].append(indexed + offset)
                    }
                }
            }
        }

        performUpdates(finalMatches, true)
    }

    nonisolated private func lineMatches(_ line: String, matcher: LineMatcher) -> Bool {
        let bytes = Array(line.utf8)
        switch matcher {
        case .literalSensitive(let needle):
            return bytes.withUnsafeBufferPointer { bp in
                guard let lb = bp.baseAddress, needle.count <= bp.count else { return false }
                return needle.withUnsafeBytes { memmem(lb, bp.count, $0.baseAddress, needle.count) != nil }
            }
        case .literalInsensitiveASCII(let needleLower):
            return bytes.withUnsafeBufferPointer { bp in
                guard let lb = bp.baseAddress else { return false }
                return needleLower.withUnsafeBufferPointer { asciiInsensitiveContainsPtr(lb, bp.count, $0.baseAddress, $0.count) }
            }
        case .multiLiteralSensitive(let needles):
            return bytes.withUnsafeBufferPointer { bp in
                guard let lb = bp.baseAddress else { return false }
                for n in needles where n.count <= bp.count {
                    if n.withUnsafeBytes({ memmem(lb, bp.count, $0.baseAddress, n.count) != nil }) { return true }
                }
                return false
            }
        case .multiLiteralInsensitiveASCII(let needles):
            return bytes.withUnsafeBufferPointer { bp in
                guard let lb = bp.baseAddress else { return false }
                for n in needles {
                    if n.withUnsafeBufferPointer({ asciiInsensitiveContainsPtr(lb, bp.count, $0.baseAddress, $0.count) }) { return true }
                }
                return false
            }
        case .regex(let rx, _, _):
            let range = NSRange(location: 0, length: line.utf16.count)
            return rx.firstMatch(in: line, options: [], range: range) != nil
        }
    }
}
