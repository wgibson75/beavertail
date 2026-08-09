//
//  VectorscanParityTests.swift
//  BeaverTailTests
//
//  Verifies that the Vectorscan-accelerated regex path produces the SAME boolean
//  match results as `NSRegularExpression` for the ASCII patterns it is allowed to
//  accelerate, and that unsupported / non-ASCII patterns are correctly declined so
//  the caller falls back. The end-to-end integration through `LogContent`'s byte
//  scan is additionally covered by `LogContentTests` (whose `f.*l` / `colou?r`
//  cases now run through Vectorscan).
//

import XCTest
@testable import BeaverTail

final class VectorscanParityTests: XCTestCase {

    /// Runs `pattern` against `line` via Vectorscan (raw bytes) and returns the
    /// boolean match result. Fails the test if the program cannot be built.
    private func vectorscanMatch(_ pattern: String, _ line: String, caseInsensitive: Bool) -> Bool {
        guard let program = VectorscanProgram(pattern: pattern, caseInsensitive: caseInsensitive) else {
            XCTFail("expected Vectorscan to compile \(pattern)")
            return false
        }
        guard let scratch = program.allocScratch() else {
            XCTFail("expected scratch allocation for \(pattern)")
            return false
        }
        defer { vectorscanFreeScratch(scratch) }

        let bytes = Array(line.utf8)
        let count = bytes.count
        // Use a stable, always-valid buffer (baseAddress is nil for empty arrays).
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(count, 1))
        defer { buffer.deallocate() }
        bytes.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { buffer.update(from: base, count: count) }
        }
        return vectorscanMatches(database: program.database, scratch: scratch, base: buffer, len: count)
    }

    /// Reference boolean match via NSRegularExpression (the fallback engine).
    private func referenceMatch(_ pattern: String, _ line: String, caseInsensitive: Bool) -> Bool {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            XCTFail("invalid reference pattern \(pattern)")
            return false
        }
        let range = NSRange(location: 0, length: line.utf16.count)
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }

    // MARK: - Parity across representative ASCII patterns

    func testVectorscanMatchesNSRegularExpressionForASCIIPatterns() {
        let patterns = [
            "f.*l", "colou?r", "a.*b", "err.*fail", ".*",
            "^error", "warn$", "[0-9]+", "ab?c", "(foo|bar)baz",
            "\\berror\\b", "colou?r|panic"
        ]
        let lines = [
            "", "error", "an error occurred", "fail whale", "funnel",
            "favourite colour", "us color", "colonel", "warn", "a warning",
            "code 42 here", "foobaz then barbaz", "ERROR upper", "nothing matches"
        ]
        for pattern in patterns {
            for line in lines {
                let expected = referenceMatch(pattern, line, caseInsensitive: false)
                let actual = vectorscanMatch(pattern, line, caseInsensitive: false)
                XCTAssertEqual(actual, expected, "pattern=\(pattern) line=\(line)")
            }
        }
    }

    func testVectorscanMatchesNSRegularExpressionCaseInsensitive() {
        let patterns = ["colou?r", "error", "warn|panic", "f.*l"]
        let lines = ["BRIGHT COLOR", "An ERROR here", "PANIC now", "FAIL", "quiet"]
        for pattern in patterns {
            for line in lines {
                let expected = referenceMatch(pattern, line, caseInsensitive: true)
                let actual = vectorscanMatch(pattern, line, caseInsensitive: true)
                XCTAssertEqual(actual, expected, "pattern=\(pattern) line=\(line) (caseInsensitive)")
            }
        }
    }

    func testEmptyMatchingPatternMatchesEveryLine() {
        // `.*` can match the empty buffer; ALLOWEMPTY makes Vectorscan agree with ICU.
        XCTAssertTrue(vectorscanMatch(".*", "", caseInsensitive: false))
        XCTAssertTrue(vectorscanMatch(".*", "anything", caseInsensitive: false))
    }

    // MARK: - Eligibility & graceful decline

    func testNonASCIIPatternIsNotAccelerated() {
        XCTAssertFalse(vectorscanCanAccelerate(pattern: "café"))
        XCTAssertTrue(vectorscanCanAccelerate(pattern: "error|warn[0-9]+"))
    }

    func testUnsupportedPatternReturnsNilProgram() {
        // Back-references are not supported by Vectorscan; the program must be nil so
        // the caller falls back to NSRegularExpression.
        XCTAssertNil(VectorscanProgram(pattern: "(a)\\1", caseInsensitive: false))
    }
}
