//
//  LineMatcherTests.swift
//  BeaverTailTests
//
//  Item 2a: LineMatcher pattern classification & required-literal extraction.
//

import XCTest
@testable import BeaverTail

@MainActor
final class LineMatcherTests: XCTestCase {

    // MARK: - make() — Happy path (classification)

    func testPlainLiteralCaseSensitive() {
        guard let matcher = LineMatcher.make(pattern: "two", caseInsensitive: false) else {
            return XCTFail("expected a matcher")
        }
        guard case let .literalSensitive(needle) = matcher else {
            return XCTFail("expected .literalSensitive, got \(matcher)")
        }
        XCTAssertEqual(needle, Array("two".utf8))
    }

    func testPlainLiteralCaseInsensitiveASCII() {
        guard let matcher = LineMatcher.make(pattern: "Hello", caseInsensitive: true) else {
            return XCTFail("expected a matcher")
        }
        guard case let .literalInsensitiveASCII(needleLower) = matcher else {
            return XCTFail("expected .literalInsensitiveASCII, got \(matcher)")
        }
        XCTAssertEqual(needleLower, Array("hello".utf8))
    }

    func testPureLiteralAlternation() {
        guard let matcher = LineMatcher.make(pattern: "one|two|three", caseInsensitive: false) else {
            return XCTFail("expected a matcher")
        }
        guard case let .multiLiteralSensitive(needles) = matcher else {
            return XCTFail("expected .multiLiteralSensitive, got \(matcher)")
        }
        XCTAssertEqual(needles, [Array("one".utf8), Array("two".utf8), Array("three".utf8)])
    }

    func testRegexWithDerivedPrefilter() {
        guard let matcher = LineMatcher.make(pattern: "colou?r", caseInsensitive: false) else {
            return XCTFail("expected a matcher")
        }
        guard case let .regex(_, prefilters, caseInsensitive) = matcher else {
            return XCTFail("expected .regex, got \(matcher)")
        }
        XCTAssertFalse(caseInsensitive)
        XCTAssertEqual(prefilters, [Array("colo".utf8)])
    }

    // MARK: - make() — Edge cases & Boundaries

    func testEmptyPatternReturnsNil() {
        XCTAssertNil(LineMatcher.make(pattern: "", caseInsensitive: false))
    }

    func testTopLevelAlternationRespectsParentheses() {
        // The `|` is nested inside parentheses, so this is NOT a pure literal
        // alternation — it must fall through to a regex matcher.
        guard let matcher = LineMatcher.make(pattern: "a(b|c)d", caseInsensitive: false) else {
            return XCTFail("expected a matcher")
        }
        guard case .regex = matcher else {
            return XCTFail("expected .regex, got \(matcher)")
        }
    }

    func testRegexOnlyWhenNoPrefilterCanBeDerived() {
        // "f.*l" has no literal run of length >= 3, so no prefilter is derived.
        guard let matcher = LineMatcher.make(pattern: "f.*l", caseInsensitive: false) else {
            return XCTFail("expected a matcher")
        }
        guard case let .regex(_, prefilters, _) = matcher else {
            return XCTFail("expected .regex, got \(matcher)")
        }
        XCTAssertTrue(prefilters.isEmpty)
    }

    // MARK: - make() — Failure modes

    func testInvalidRegexReturnsNil() {
        XCTAssertNil(LineMatcher.make(pattern: "[unclosed", caseInsensitive: false))
    }

    // MARK: - requiredLiteral(in:)

    func testRequiredLiteralPicksLongestRun() {
        XCTAssertEqual(LineMatcher.requiredLiteral(in: "err.*fail"), "fail")
    }

    func testRequiredLiteralAcceptsShortWholeLiteral() {
        XCTAssertEqual(LineMatcher.requiredLiteral(in: "ab"), "ab")
    }

    func testRequiredLiteralReturnsNilForShortInteriorRun() {
        XCTAssertNil(LineMatcher.requiredLiteral(in: "a.b"))
    }

    func testRequiredLiteralReturnsNilWhenAlternationPresent() {
        XCTAssertNil(LineMatcher.requiredLiteral(in: "foo|bar"))
    }

    // MARK: - requiredLiterals(in:)

    func testRequiredLiteralsExtractsOnePerBranch() {
        XCTAssertEqual(LineMatcher.requiredLiterals(in: "foo|bar"), ["foo", "bar"])
    }

    func testRequiredLiteralsReturnsNilWhenAnyBranchLacksLiteral() {
        XCTAssertNil(LineMatcher.requiredLiterals(in: "foo|a.b"))
    }
}
