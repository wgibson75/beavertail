//
//  HighlightObjectCacheTests.swift
//  BeaverTailTests
//
//  Model cleanup: HighlightRule is now pure Codable value data, with its derived
//  NSColor / NSRegularExpression served by the memoising HighlightObjectCache.
//  These tests lock in that the derived objects are correct, respect
//  case-sensitivity, and are cached (identical inputs → the same instance).
//

import XCTest
import AppKit
import SwiftUI
@testable import BeaverTail

final class HighlightObjectCacheTests: XCTestCase {

    // MARK: - regex — Happy path, case sensitivity, failure

    func testRegexCompilesAndMatches() {
        guard let rx = HighlightObjectCache.regex(pattern: "a.*b", caseSensitive: true) else {
            return XCTFail("expected a compiled regex")
        }
        XCTAssertNotNil(rx.firstMatch(in: "axxb", options: [], range: NSRange(location: 0, length: 4)))
    }

    func testRegexRespectsCaseSensitivity() {
        let sensitive = HighlightObjectCache.regex(pattern: "abc", caseSensitive: true)
        let insensitive = HighlightObjectCache.regex(pattern: "abc", caseSensitive: false)
        let upper = "ABC"
        let range = NSRange(location: 0, length: upper.utf16.count)
        XCTAssertNil(sensitive?.firstMatch(in: upper, options: [], range: range))
        XCTAssertNotNil(insensitive?.firstMatch(in: upper, options: [], range: range))
    }

    func testInvalidPatternReturnsNil() {
        XCTAssertNil(HighlightObjectCache.regex(pattern: "[unclosed", caseSensitive: false))
    }

    func testRegexIsCachedPerPatternAndCaseSensitivity() {
        let a = HighlightObjectCache.regex(pattern: "cache-me", caseSensitive: true)
        let b = HighlightObjectCache.regex(pattern: "cache-me", caseSensitive: true)
        XCTAssertNotNil(a)
        // Same key → same memoised instance.
        XCTAssertTrue(a === b)
        // Different case-sensitivity is a different key → a different instance.
        let c = HighlightObjectCache.regex(pattern: "cache-me", caseSensitive: false)
        XCTAssertFalse(a === c)
    }

    // MARK: - color — correctness, fallback, caching

    private func components(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    func testColorParsesHex() {
        let red = components(HighlightObjectCache.color(hex: "FF0000", role: "bg", fallback: .yellow))
        XCTAssertEqual(red.r, 1, accuracy: 0.02)
        XCTAssertEqual(red.g, 0, accuracy: 0.02)
        XCTAssertEqual(red.b, 0, accuracy: 0.02)
    }

    func testColorFallsBackForInvalidHex() {
        // An unparseable hex resolves to the supplied fallback colour (whatever the
        // platform renders SwiftUI's `.yellow` as — compare against that, not an
        // assumed pure (1,1,0), since system colours aren't exact sRGB primaries).
        let expected = components(NSColor(Color.yellow))
        let got = components(HighlightObjectCache.color(hex: "not-a-hex", role: "bgFallback", fallback: .yellow))
        XCTAssertEqual(got.r, expected.r, accuracy: 0.02)
        XCTAssertEqual(got.g, expected.g, accuracy: 0.02)
        XCTAssertEqual(got.b, expected.b, accuracy: 0.02)
    }

    func testColorIsCachedPerHexAndRole() {
        let a = HighlightObjectCache.color(hex: "112233", role: "fg", fallback: .black)
        let b = HighlightObjectCache.color(hex: "112233", role: "fg", fallback: .black)
        XCTAssertTrue(a === b)
    }

    // MARK: - HighlightRule derived accessors reflect the value data

    func testRuleDerivedObjectsReflectData() {
        let rule = HighlightRule(
            pattern: "error", foregroundColorHex: "FFFFFF", backgroundColorHex: "FF0000"
        )
        let bg = components(rule.nsBackgroundColor)
        XCTAssertEqual(bg.r, 1, accuracy: 0.02)
        XCTAssertEqual(bg.g, 0, accuracy: 0.02)
        XCTAssertEqual(bg.b, 0, accuracy: 0.02)
        XCTAssertNotNil(rule.compiledRegex)
    }

    func testRuleCaseSensitiveFlagDrivesCompiledRegex() {
        let sensitive = HighlightRule(
            pattern: "abc", foregroundColorHex: "FFFFFF", backgroundColorHex: "FFFF00",
            isCaseSensitive: true
        )
        let insensitive = HighlightRule(
            pattern: "abc", foregroundColorHex: "FFFFFF", backgroundColorHex: "FFFF00",
            isCaseSensitive: false
        )
        let range = NSRange(location: 0, length: 3)
        XCTAssertNil(sensitive.compiledRegex?.firstMatch(in: "ABC", options: [], range: range))
        XCTAssertNotNil(insensitive.compiledRegex?.firstMatch(in: "ABC", options: [], range: range))
    }
}
