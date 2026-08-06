//
//  HighlightCodableTests.swift
//  BeaverTailTests
//
//  Item 8: HighlightRule codable/regex compilation and HighlightFiltersDocument
//  encode/decode + legacy-data handling.
//

import XCTest
@testable import BeaverTail

@MainActor
final class HighlightCodableTests: XCTestCase {

    // MARK: - HighlightRule — Happy path

    func testHighlightRuleRoundTripPreservesFieldsButRegeneratesID() throws {
        let original = HighlightRule(
            pattern: "error",
            foregroundColorHex: "FFFFFF",
            backgroundColorHex: "FF0000",
            isCaseSensitive: true,
            isEnabled: false,
            groupID: UUID()
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HighlightRule.self, from: data)

        XCTAssertEqual(decoded.pattern, original.pattern)
        XCTAssertEqual(decoded.foregroundColorHex, original.foregroundColorHex)
        XCTAssertEqual(decoded.backgroundColorHex, original.backgroundColorHex)
        XCTAssertEqual(decoded.isCaseSensitive, original.isCaseSensitive)
        XCTAssertEqual(decoded.isEnabled, original.isEnabled)
        XCTAssertEqual(decoded.groupID, original.groupID)
        // Decoding intentionally assigns a fresh id.
        XCTAssertNotEqual(decoded.id, original.id)
    }

    // MARK: - HighlightRule — Edge cases (legacy data)

    func testHighlightRuleLegacyDataAppliesDefaults() throws {
        let legacyJSON = """
        {"pattern":"warn","foregroundColorHex":"000000","backgroundColorHex":"FFFF00"}
        """
        let decoded = try JSONDecoder().decode(HighlightRule.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(decoded.isCaseSensitive)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertNil(decoded.groupID)
    }

    // MARK: - HighlightRule — regex compilation & signature

    func testValidPatternCompilesRegex() {
        let rule = HighlightRule(pattern: "a.*b", foregroundColorHex: "FFFFFF", backgroundColorHex: "FFFF00")
        XCTAssertNotNil(rule.compiledRegex)
    }

    func testInvalidPatternLeavesRegexNil() {
        let rule = HighlightRule(pattern: "[unclosed", foregroundColorHex: "FFFFFF", backgroundColorHex: "FFFF00")
        XCTAssertNil(rule.compiledRegex)
    }

    func testCaseSensitivityAffectsSignature() {
        let id = UUID()
        let enabled = HighlightRule(id: id, pattern: "p", foregroundColorHex: "FFFFFF",
                                    backgroundColorHex: "FFFF00", isEnabled: true)
        let disabled = HighlightRule(id: id, pattern: "p", foregroundColorHex: "FFFFFF",
                                     backgroundColorHex: "FFFF00", isEnabled: false)
        XCTAssertNotEqual(enabled.signature, disabled.signature)
    }

    // MARK: - HighlightFilterItem disambiguation

    func testDecodesGroupItemWhenGroupKeysPresent() throws {
        let json = """
        {"groupName":"Errors","isEnabled":true,"rules":[
            {"pattern":"err","foregroundColorHex":"FFFFFF","backgroundColorHex":"FF0000","isCaseSensitive":false,"isEnabled":true}
        ]}
        """
        let item = try JSONDecoder().decode(HighlightFilterItem.self, from: Data(json.utf8))
        guard case let .group(group) = item else {
            return XCTFail("expected .group, got \(item)")
        }
        XCTAssertEqual(group.groupName, "Errors")
        XCTAssertEqual(group.rules.count, 1)
        XCTAssertEqual(group.rules.first?.pattern, "err")
    }

    func testDecodesRuleItemWhenGroupKeysAbsent() throws {
        let json = """
        {"pattern":"info","foregroundColorHex":"FFFFFF","backgroundColorHex":"00FF00","isCaseSensitive":true,"isEnabled":false}
        """
        let item = try JSONDecoder().decode(HighlightFilterItem.self, from: Data(json.utf8))
        guard case let .rule(rule) = item else {
            return XCTFail("expected .rule, got \(item)")
        }
        XCTAssertEqual(rule.pattern, "info")
        XCTAssertTrue(rule.isCaseSensitive)
        XCTAssertFalse(rule.isEnabled)
    }

    // MARK: - HighlightFiltersDocument round trip

    func testDocumentRoundTripPreservesMixedItems() throws {
        let ruleDTO = HighlightFilterRuleDTO(
            pattern: "plain", foregroundColorHex: "FFFFFF", backgroundColorHex: "FFFF00",
            isCaseSensitive: false, isEnabled: true
        )
        let groupDTO = HighlightFilterGroupDTO(
            groupName: "G", isEnabled: false,
            rules: [HighlightFilterRuleDTO(
                pattern: "member", foregroundColorHex: "000000", backgroundColorHex: "FF0000",
                isCaseSensitive: true, isEnabled: true
            )]
        )
        let document = HighlightFiltersDocument(rules: [.rule(ruleDTO), .group(groupDTO)])

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(HighlightFiltersDocument.self, from: data)

        XCTAssertEqual(decoded.rules.count, 2)
        guard case let .rule(decodedRule) = decoded.rules[0] else {
            return XCTFail("expected first item to be a rule")
        }
        XCTAssertEqual(decodedRule.pattern, "plain")
        guard case let .group(decodedGroup) = decoded.rules[1] else {
            return XCTFail("expected second item to be a group")
        }
        XCTAssertEqual(decodedGroup.groupName, "G")
        XCTAssertFalse(decodedGroup.isEnabled)
        XCTAssertEqual(decodedGroup.rules.first?.pattern, "member")
    }

    // MARK: - HighlightFilterRuleDTO legacy defaults

    func testRuleDTOLegacyDataAppliesDefaults() throws {
        let json = """
        {"pattern":"x","foregroundColorHex":"FFFFFF","backgroundColorHex":"FFFF00"}
        """
        let dto = try JSONDecoder().decode(HighlightFilterRuleDTO.self, from: Data(json.utf8))
        XCTAssertFalse(dto.isCaseSensitive)
        XCTAssertTrue(dto.isEnabled)
    }
}
