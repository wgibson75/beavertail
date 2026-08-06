//
//  ColorHexTests.swift
//  BeaverTailTests
//
//  Item 9: hex <-> Color conversion helpers.
//

import XCTest
import SwiftUI
@testable import BeaverTail

@MainActor
final class ColorHexTests: XCTestCase {

    // MARK: - Happy path

    func testRoundTripPrimaryColours() {
        XCTAssertEqual(Color(hex: "FF0000")?.toHex(), "FF0000")
        XCTAssertEqual(Color(hex: "00FF00")?.toHex(), "00FF00")
        XCTAssertEqual(Color(hex: "0000FF")?.toHex(), "0000FF")
    }

    func testRoundTripBlackAndWhite() {
        XCTAssertEqual(Color(hex: "000000")?.toHex(), "000000")
        XCTAssertEqual(Color(hex: "FFFFFF")?.toHex(), "FFFFFF")
    }

    // MARK: - Edge cases & Boundaries

    func testLeadingHashIsAccepted() {
        XCTAssertEqual(Color(hex: "#00FF00")?.toHex(), "00FF00")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(Color(hex: "  #0000FF  ")?.toHex(), "0000FF")
    }

    func testLowercaseHexIsAccepted() {
        XCTAssertEqual(Color(hex: "00ff00")?.toHex(), "00FF00")
    }

    // MARK: - Failure modes

    func testNonHexStringReturnsNil() {
        XCTAssertNil(Color(hex: "nothex"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(Color(hex: ""))
    }
}
