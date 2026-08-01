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
        if let encodedGroups = try? JSONEncoder().encode(highlightRulesStore.groups),
           let groupString = String(data: encodedGroups, encoding: .utf8) {
            if groupsData != groupString { groupsData = groupString }
        }
    }

    func loadRules() {
        if !rulesData.isEmpty,
           let data = rulesData.data(using: .utf8),
           var decoded = try? JSONDecoder().decode([HighlightRule].self, from: data) {
            for idx in 0 ..< decoded.count { decoded[idx].updateCachedObjects() }
            highlightRules = decoded
        }
        if !groupsData.isEmpty,
           let data = groupsData.data(using: .utf8),
           let decodedGroups = try? JSONDecoder().decode([HighlightGroup].self, from: data) {
            highlightRulesStore.groups = decodedGroups
        }
    }

}
