//
//  VectorscanEngine.swift
//  BeaverTail
//
//  Thin Swift wrapper over the vendored Vectorscan (Hyperscan-compatible) C API.
//  It accelerates the per-line *regex confirmation* step of the filter and
//  highlight scans: instead of decoding each candidate line into a String and
//  running `NSRegularExpression`, we run Vectorscan's block-mode matcher directly
//  over the memory-mapped bytes. Vectorscan is designed for exactly this —
//  high-throughput scanning that is safe to run concurrently as long as each
//  worker thread owns its own scratch space, which is how `LogContent`'s
//  `DispatchQueue.concurrentPerform` chunk workers use it.
//
//  Parity: a program is only built for ASCII patterns, and matching is compared
//  against the memory-mapped bytes. Any pattern Vectorscan cannot compile (or a
//  non-ASCII pattern) yields `nil`, and the caller transparently falls back to
//  the existing `NSRegularExpression` path, so observable results are unchanged.
//

import Foundation

/// Non-capturing C match callback. Vectorscan invokes this synchronously from
/// within `hs_scan` for each match. We only need a boolean "did it match?", so we
/// flip the `Int32` flag pointed to by `context` and return a non-zero value,
/// which tells `hs_scan` to stop scanning immediately.
private nonisolated func beaverTailVectorscanOnMatch(
    _ id: UInt32,
    _ from: UInt64,
    _ to: UInt64,
    _ flags: UInt32,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    context?.assumingMemoryBound(to: Int32.self).pointee = 1
    return 1
}

/// A compiled Vectorscan block-mode database for a single regex pattern.
///
/// The database is immutable after compilation and is safe to share across threads
/// for scanning, provided each concurrent caller uses its own scratch (obtained via
/// `vectorscanAllocScratch(_:)`). Marked `@unchecked Sendable` on that basis so it
/// can be captured by the parallel chunk workers in `LogContent`.
nonisolated final class VectorscanProgram: @unchecked Sendable {
    /// Opaque `hs_database_t *`.
    let database: OpaquePointer

    /// Builds a program for `pattern`, or returns `nil` when Vectorscan cannot
    /// compile it (an unsupported construct such as a back-reference). Callers fall
    /// back to `NSRegularExpression` on `nil`.
    ///
    /// Flags:
    /// - `HS_FLAG_SINGLEMATCH` — we only care whether a line matches, so one match
    ///   per line is sufficient (and lets the callback halt scanning early).
    /// - `HS_FLAG_ALLOWEMPTY` — permit patterns that can match the empty buffer
    ///   (e.g. `.*`), matching `NSRegularExpression`, which allows empty matches.
    /// - `HS_FLAG_CASELESS` — ASCII case-insensitive matching when requested.
    init?(pattern: String, caseInsensitive: Bool) {
        var flags = UInt32(HS_FLAG_SINGLEMATCH) | UInt32(HS_FLAG_ALLOWEMPTY)
        if caseInsensitive { flags |= UInt32(HS_FLAG_CASELESS) }

        var db: OpaquePointer?
        var compileError: UnsafeMutablePointer<hs_compile_error_t>?
        let status = pattern.withCString { cstr in
            hs_compile(cstr, flags, UInt32(HS_MODE_BLOCK), nil, &db, &compileError)
        }
        if let compileError { hs_free_compile_error(compileError) }
        guard status == 0, let compiled = db else {
            if let db { hs_free_database(db) }
            return nil
        }
        self.database = compiled
    }

    deinit {
        hs_free_database(database)
    }

    /// Allocates a fresh scratch space bound to this database for exclusive use by a
    /// single worker thread. `hs_alloc_scratch` is NOT safe to call concurrently, so
    /// callers must serialize it via `vectorscanAllocScratch(_:)`. Returns `nil` on
    /// allocation failure. Free with `vectorscanFreeScratch(_:)`.
    func allocScratch() -> OpaquePointer? {
        var scratch: OpaquePointer?
        guard hs_alloc_scratch(database, &scratch) == 0 else { return nil }
        return scratch
    }
}

/// `hs_alloc_scratch` / `hs_clone_scratch` are documented as NOT thread-safe: they
/// must not be called concurrently. BeaverTail's scans run across up to ~128
/// parallel workers that each need their own scratch, so ALL scratch allocation and
/// freeing is funnelled through this lock. Contention is negligible (a handful of
/// allocations per worker, once, at chunk start/end) but it eliminates the data
/// race that could corrupt Hyperscan's allocator and stall large scans.
private nonisolated let vectorscanScratchLock = NSLock()

/// Thread-safe scratch allocation for a single-pattern program (see lock note).
@inline(__always)
nonisolated func vectorscanAllocScratch(_ program: VectorscanProgram?) -> OpaquePointer? {
    guard let program else { return nil }
    vectorscanScratchLock.lock()
    defer { vectorscanScratchLock.unlock() }
    return program.allocScratch()
}

/// Thread-safe scratch allocation for a fused multi-pattern program.
@inline(__always)
nonisolated func vectorscanAllocScratch(_ program: VectorscanMultiProgram?) -> OpaquePointer? {
    guard let program else { return nil }
    vectorscanScratchLock.lock()
    defer { vectorscanScratchLock.unlock() }
    return program.allocScratch()
}

/// Frees a scratch previously obtained from `vectorscanAllocScratch(_:)`. Serialized
/// through the same lock so it never races a concurrent allocation.
@inline(__always)
nonisolated func vectorscanFreeScratch(_ scratch: OpaquePointer?) {
    guard let scratch else { return }
    vectorscanScratchLock.lock()
    defer { vectorscanScratchLock.unlock() }
    hs_free_scratch(scratch)
}

/// Boolean block-mode scan: does `[base, base + len)` match `database`? `scratch`
/// must be exclusive to the calling thread. Operates directly on the memory-mapped
/// bytes — no String decode, no allocation.
@inline(__always)
nonisolated func vectorscanMatches(
    database: OpaquePointer,
    scratch: OpaquePointer,
    base: UnsafePointer<UInt8>,
    len: Int
) -> Bool {
    var matched: Int32 = 0
    let dataPtr = UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self)
    withUnsafeMutablePointer(to: &matched) { flagPtr in
        _ = hs_scan(
            database, dataPtr, UInt32(len), 0, scratch,
            beaverTailVectorscanOnMatch, UnsafeMutableRawPointer(flagPtr)
        )
    }
    return matched != 0
}

/// Whether `pattern` is safe to hand to Vectorscan while preserving parity with the
/// `NSRegularExpression` path. Restricted to ASCII patterns: Vectorscan scans the
/// raw (possibly non-UTF-8) bytes, and for ASCII patterns its byte-level semantics
/// match ICU's for the boolean "does this line match?" question. Any non-ASCII
/// pattern falls back to `NSRegularExpression`.
@inline(__always)
nonisolated func vectorscanCanAccelerate(pattern: String) -> Bool {
    pattern.utf8.allSatisfy { $0 < 0x80 }
}

// MARK: - Fused multi-pattern matching

/// Non-capturing C callback for multi-pattern scans. `context` points to a `Bool`
/// buffer sized to the number of patterns in the database; it records that the
/// pattern with the given `id` matched. Returns 0 to keep scanning so every matching
/// pattern is recorded (each fires at most once thanks to `HS_FLAG_SINGLEMATCH`, so
/// there is no match explosion).
private nonisolated func beaverTailVectorscanMultiOnMatch(
    _ id: UInt32,
    _ from: UInt64,
    _ to: UInt64,
    _ flags: UInt32,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    context?.assumingMemoryBound(to: Bool.self)[Int(id)] = true
    return 0
}

/// A single Vectorscan database that fuses MANY patterns into one automaton, so a
/// line can be scanned once for all of them instead of once per pattern. Used to
/// accelerate highlight generation, which tests every line against every rule.
/// Immutable after compilation and safe to share across threads for scanning,
/// provided each worker uses its own scratch.
nonisolated final class VectorscanMultiProgram: @unchecked Sendable {
    /// Opaque `hs_database_t *`.
    let database: OpaquePointer
    /// Number of patterns compiled in; pattern ids are `0 ..< patternCount`.
    let patternCount: Int
    /// Maps each surviving pattern id back to its index in the `expressions` array
    /// passed to `init`. Any expression Vectorscan could not compile is dropped, so
    /// this is how the caller re-associates fused ids with its original rules.
    let sourceIndices: [Int]

    /// Compiles `expressions` (each with its own case-sensitivity) into one database.
    /// Expressions that Vectorscan rejects are dropped (and reported via
    /// `sourceIndices`) rather than failing the whole set, so a single exotic rule
    /// doesn't disable fusion for the rest. Returns `nil` only if nothing compiles.
    init?(expressions: [(pattern: String, caseInsensitive: Bool)]) {
        guard !expressions.isEmpty else { return nil }
        // (originalIndex, pattern, caseInsensitive); drop rejected entries and retry.
        var working = expressions.enumerated().map {
            (origIndex: $0.offset, pattern: $0.element.pattern, caseInsensitive: $0.element.caseInsensitive)
        }

        while !working.isEmpty {
            var owned: [UnsafeMutablePointer<CChar>] = []
            owned.reserveCapacity(working.count)
            var duplicationFailed = false
            for entry in working {
                if let dup = strdup(entry.pattern) { owned.append(dup) } else { duplicationFailed = true; break }
            }
            defer { owned.forEach { free($0) } }
            if duplicationFailed { return nil }

            let cStrings: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
            var flags = [UInt32]()
            var ids = [UInt32]()
            flags.reserveCapacity(working.count)
            ids.reserveCapacity(working.count)
            for (index, entry) in working.enumerated() {
                var flag = UInt32(HS_FLAG_SINGLEMATCH) | UInt32(HS_FLAG_ALLOWEMPTY)
                if entry.caseInsensitive { flag |= UInt32(HS_FLAG_CASELESS) }
                flags.append(flag)
                ids.append(UInt32(index))
            }

            var db: OpaquePointer?
            var compileError: UnsafeMutablePointer<hs_compile_error_t>?
            let status = cStrings.withUnsafeBufferPointer { cs in
                flags.withUnsafeBufferPointer { fl in
                    ids.withUnsafeBufferPointer { idp in
                        hs_compile_multi(
                            cs.baseAddress, fl.baseAddress, idp.baseAddress,
                            UInt32(working.count), UInt32(HS_MODE_BLOCK), nil, &db, &compileError
                        )
                    }
                }
            }

            if status == 0, let compiled = db {
                if let compileError { hs_free_compile_error(compileError) }
                self.database = compiled
                self.patternCount = working.count
                self.sourceIndices = working.map { $0.origIndex }
                return
            }

            // Compilation failed: drop the offending expression (when identified) and
            // retry with the rest; give up if the failure isn't attributable.
            let dropIndex = compileError.map { Int($0.pointee.expression) }
            if let compileError { hs_free_compile_error(compileError) }
            if let db { hs_free_database(db) }
            guard let dropIndex, dropIndex >= 0, dropIndex < working.count else { return nil }
            working.remove(at: dropIndex)
        }
        return nil
    }

    deinit {
        hs_free_database(database)
    }

    /// A fresh scratch bound to this database. `hs_alloc_scratch` is not
    /// concurrent-safe, so callers must serialize via `vectorscanAllocScratch(_:)`.
    func allocScratch() -> OpaquePointer? {
        var scratch: OpaquePointer?
        guard hs_alloc_scratch(database, &scratch) == 0 else { return nil }
        return scratch
    }
}

/// Scans `[base, base + len)` against a fused multi-pattern `database`, recording
/// which patterns matched into `hits` (a caller-owned `Bool` buffer sized to the
/// database's `patternCount`, which the caller resets to `false` before the call).
/// `scratch` must be exclusive to the calling thread.
@inline(__always)
nonisolated func vectorscanScanMulti(
    database: OpaquePointer,
    scratch: OpaquePointer,
    base: UnsafePointer<UInt8>,
    len: Int,
    hits: UnsafeMutablePointer<Bool>
) {
    let dataPtr = UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self)
    _ = hs_scan(
        database, dataPtr, UInt32(len), 0, scratch,
        beaverTailVectorscanMultiOnMatch, UnsafeMutableRawPointer(hits)
    )
}

extension LineMatcher {
    /// The `(pattern, caseInsensitive)` used to fuse this matcher into a Vectorscan
    /// multi-pattern database, so highlight generation can scan each line once for
    /// every rule. Literal and multi-literal matchers are reconstructed as escaped
    /// literals / alternations; regex matchers pass their pattern through. Returns
    /// `nil` for any matcher containing non-ASCII bytes (those keep the
    /// `NSRegularExpression` / byte-scanner fallback to preserve parity).
    nonisolated var vectorscanFusibleExpression: (pattern: String, caseInsensitive: Bool)? {
        switch self {
        case .literalSensitive(let needle):
            return Self.asciiEscapedLiteral(needle).map { ($0, false) }
        case .literalInsensitiveASCII(let needleLower):
            return Self.asciiEscapedLiteral(needleLower).map { ($0, true) }
        case .multiLiteralSensitive(let needles):
            return Self.asciiEscapedAlternation(needles).map { ($0, false) }
        case .multiLiteralInsensitiveASCII(let needles):
            return Self.asciiEscapedAlternation(needles).map { ($0, true) }
        case .regex(let regex, _, let caseInsensitive):
            return regex.pattern.utf8.allSatisfy({ $0 < 0x80 }) ? (regex.pattern, caseInsensitive) : nil
        }
    }

    /// Escaped regex literal for `bytes`, or nil if any byte is non-ASCII.
    nonisolated private static func asciiEscapedLiteral(_ bytes: [UInt8]) -> String? {
        guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        return NSRegularExpression.escapedPattern(for: String(decoding: bytes, as: UTF8.self))
    }

    /// Escaped `a|b|c` alternation for `needles`, or nil if any is non-ASCII/empty.
    nonisolated private static func asciiEscapedAlternation(_ needles: [[UInt8]]) -> String? {
        guard !needles.isEmpty else { return nil }
        var parts: [String] = []
        parts.reserveCapacity(needles.count)
        for needle in needles {
            guard let literal = asciiEscapedLiteral(needle) else { return nil }
            parts.append(literal)
        }
        return parts.joined(separator: "|")
    }
}
