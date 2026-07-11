import Foundation
import SwiftUI
import AppKit

extension LogViewModel {
    // MARK: - Rules

    func saveRules() {
        if let encoded = try? JSONEncoder().encode(highlightRules),
           let string = String(data: encoded, encoding: .utf8) {
            if rulesData != string { rulesData = string }
        }
    }

    func loadRules() {
        guard !rulesData.isEmpty,
              let data = rulesData.data(using: .utf8),
              var decoded = try? JSONDecoder().decode([HighlightRule].self, from: data)
        else { return }
        for idx in 0 ..< decoded.count { decoded[idx].updateCachedObjects() }
        highlightRules = decoded
    }

}
