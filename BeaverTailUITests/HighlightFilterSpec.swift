//
//  HighlightFilterSpec.swift
//  BeaverTailUITests
//
//  A minimal, self-contained description of a highlight filter that the UI tests
//  inject into the app via the UserDefaults argument domain (`-saved_highlight_rules`).
//  Encoding here mirrors the app's `HighlightRule` Codable keys exactly, so the app
//  decodes these into real, active highlight rules — without the tests depending on
//  whatever filters the developer happens to have configured on their machine.
//

import Foundation

struct HighlightFilterSpec {
    let pattern: String
    var foregroundColorHex: String = "#FFFFFF"
    var backgroundColorHex: String
    var isCaseSensitive: Bool = false
    var isEnabled: Bool = true

    init(
        pattern: String,
        foreground: String = "#FFFFFF",
        background: String,
        isCaseSensitive: Bool = false,
        isEnabled: Bool = true
    ) {
        self.pattern = pattern
        self.foregroundColorHex = foreground
        self.backgroundColorHex = background
        self.isCaseSensitive = isCaseSensitive
        self.isEnabled = isEnabled
    }

    /// Keys and shape must match `HighlightRule`'s `CodingKeys`. `groupID` is
    /// deliberately omitted so every injected filter is ungrouped and active.
    private enum CodingKeys: String, CodingKey {
        case pattern, foregroundColorHex, backgroundColorHex, isCaseSensitive, isEnabled
    }

    /// JSON string for an array of specs, ready to hand to `-saved_highlight_rules`.
    static func json(for specs: [HighlightFilterSpec]) -> String {
        let objects: [[String: Any]] = specs.map {
            [
                "pattern": $0.pattern,
                "foregroundColorHex": $0.foregroundColorHex,
                "backgroundColorHex": $0.backgroundColorHex,
                "isCaseSensitive": $0.isCaseSensitive,
                "isEnabled": $0.isEnabled
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
