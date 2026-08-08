//
//  FilteringEngineTests.swift
//  BeaverTailTests
//
//  FilteringEngine extraction: the service facade over pattern compilation and the
//  pure per-line `matches` across every LineMatcher kind. (Classification and
//  required-literal extraction are additionally covered by LineMatcherTests, which
//  exercise the same relocated code via `LineMatcher.make`.)
//

import XCTest
@testable import BeaverTail

final class FilteringEngineTests: XCTestCase {

    private func compile(_ pattern: String, caseInsensitive: Bool = false) -> LineMatcher {
        guard let matcher = FilteringEngine.compile(pattern: pattern, caseInsensitive: caseInsensitive) else {
            fatalError("expected a matcher for \(pattern)")
        }
        return matcher
    }

    // MARK: - compile — Happy path & Failure modes

    func testCompileProducesFastestMatcherKind() {
        guard case .literalSensitive = compile("error") else { return XCTFail("expected literal") }
        guard case .multiLiteralSensitive = compile("one|two|three") else { return XCTFail("expected multi-literal") }
        guard case .regex = compile("colou?r") else { return XCTFail("expected regex") }
    }

    func testCompileReturnsNilForEmptyOrInvalidPattern() {
        XCTAssertNil(FilteringEngine.compile(pattern: "", caseInsensitive: false))
        XCTAssertNil(FilteringEngine.compile(pattern: "[unclosed", caseInsensitive: false))
    }

    // MARK: - matches — one case per matcher kind

    func testMatchesLiteralSensitive() {
        let matcher = compile("two")
        XCTAssertTrue(FilteringEngine.matches("one two three", using: matcher))
        XCTAssertFalse(FilteringEngine.matches("one three", using: matcher))
        // Case-sensitive: an uppercased needle must not match.
        XCTAssertFalse(FilteringEngine.matches("one TWO three", using: matcher))
    }

    func testMatchesLiteralInsensitiveASCII() {
        let matcher = compile("TWO", caseInsensitive: true)
        XCTAssertTrue(FilteringEngine.matches("one two three", using: matcher))
        XCTAssertTrue(FilteringEngine.matches("one TwO three", using: matcher))
        XCTAssertFalse(FilteringEngine.matches("one three", using: matcher))
    }

    func testMatchesMultiLiteralSensitive() {
        let matcher = compile("one|three")
        XCTAssertTrue(FilteringEngine.matches("aaa three bbb", using: matcher))
        XCTAssertTrue(FilteringEngine.matches("one only", using: matcher))
        XCTAssertFalse(FilteringEngine.matches("two only", using: matcher))
        XCTAssertFalse(FilteringEngine.matches("THREE upper", using: matcher))
    }

    func testMatchesMultiLiteralInsensitiveASCII() {
        let matcher = compile("one|four", caseInsensitive: true)
        XCTAssertTrue(FilteringEngine.matches("say ONE now", using: matcher))
        XCTAssertTrue(FilteringEngine.matches("the FoUr", using: matcher))
        XCTAssertFalse(FilteringEngine.matches("two three", using: matcher))
    }

    func testMatchesRegexOnly() {
        // "f.*l" derives no pre-filter (no literal run >= 3).
        let matcher = compile("f.*l")
        XCTAssertTrue(FilteringEngine.matches("fail", using: matcher))
        XCTAssertTrue(FilteringEngine.matches("a funnel here", using: matcher))
        XCTAssertFalse(FilteringEngine.matches("nope", using: matcher))
    }

    func testMatchesRegexWithDerivedPrefilter() {
        let matcher = compile("colou?r")
        XCTAssertTrue(FilteringEngine.matches("favourite colour", using: matcher))
        XCTAssertTrue(FilteringEngine.matches("us color", using: matcher))
        XCTAssertFalse(FilteringEngine.matches("colonel", using: matcher))
    }

    func testMatchesRegexCaseInsensitive() {
        let matcher = compile("colou?r", caseInsensitive: true)
        XCTAssertTrue(FilteringEngine.matches("BRIGHT COLOR", using: matcher))
    }

    // MARK: - matches — Edge cases

    func testMatchesEmptyLineNeverMatchesNonEmptyNeedle() {
        XCTAssertFalse(FilteringEngine.matches("", using: compile("x")))
        XCTAssertFalse(FilteringEngine.matches("", using: compile("a|b")))
    }

    func testMatchesNeedleLongerThanLine() {
        XCTAssertFalse(FilteringEngine.matches("hi", using: compile("hello")))
    }

    // MARK: - required-literal facade

    func testRequiredLiteralFacade() {
        XCTAssertEqual(FilteringEngine.requiredLiteral(in: "err.*fail"), "fail")
        XCTAssertNil(FilteringEngine.requiredLiteral(in: "foo|bar"))
    }

    func testRequiredLiteralsFacade() {
        XCTAssertEqual(FilteringEngine.requiredLiterals(in: "foo|bar"), ["foo", "bar"])
        XCTAssertNil(FilteringEngine.requiredLiterals(in: "foo|a.b"))
    }
}
