//
//  UpdateServiceTests.swift
//  BeaverTailTests
//
//  Item 12: version normalization & comparison (the network fetch is left to an
//  integration test with a URLProtocol stub).
//

import XCTest
@testable import BeaverTail

final class UpdateServiceTests: XCTestCase {

    // MARK: - compareVersions — Happy path

    func testCompareOrdersPatchVersions() {
        XCTAssertEqual(UpdateService.compareVersions("1.2.0", "1.2.1"), -1)
        XCTAssertEqual(UpdateService.compareVersions("1.2.1", "1.2.0"), 1)
        XCTAssertEqual(UpdateService.compareVersions("1.2.0", "1.2.0"), 0)
    }

    func testCompareOrdersMajorAndMinor() {
        XCTAssertEqual(UpdateService.compareVersions("2.0.0", "1.9.9"), 1)
        XCTAssertEqual(UpdateService.compareVersions("1.3.0", "1.4.0"), -1)
    }

    // MARK: - compareVersions — Edge cases & Boundaries

    func testMissingTrailingComponentsTreatedAsZero() {
        XCTAssertEqual(UpdateService.compareVersions("1.2", "1.2.0"), 0)
        XCTAssertEqual(UpdateService.compareVersions("1.2", "1.2.1"), -1)
    }

    func testLeadingZerosAreNumericallyEqual() {
        XCTAssertEqual(UpdateService.compareVersions("1.02", "1.2"), 0)
    }

    func testEmptyVersionIsLowest() {
        XCTAssertEqual(UpdateService.compareVersions("", "1.0.0"), -1)
        XCTAssertEqual(UpdateService.compareVersions("", ""), 0)
    }

    // MARK: - compareVersions — Failure modes (graceful)

    func testNonNumericComponentsTreatedAsZero() {
        // "x" parses as 0, so "1.x" == "1.0".
        XCTAssertEqual(UpdateService.compareVersions("1.x", "1.0"), 0)
    }

    // MARK: - normalizedVersion

    func testStripsLeadingLowercaseV() {
        XCTAssertEqual(UpdateService.normalizedVersion(from: "v1.4.0"), "1.4.0")
    }

    func testStripsLeadingUppercaseV() {
        XCTAssertEqual(UpdateService.normalizedVersion(from: "V2.0"), "2.0")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(UpdateService.normalizedVersion(from: "  1.0.0  "), "1.0.0")
    }

    func testPlainVersionIsUnchanged() {
        XCTAssertEqual(UpdateService.normalizedVersion(from: "3.1.4"), "3.1.4")
    }

    func testEmptyStringNormalizesToEmpty() {
        XCTAssertEqual(UpdateService.normalizedVersion(from: ""), "")
    }
}
