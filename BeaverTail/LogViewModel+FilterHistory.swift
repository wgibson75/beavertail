import Foundation
import SwiftUI
import AppKit

extension LogViewModel {
    // MARK: - Filter History

    func addToFilterHistory(_ pattern: String) {
        guard !pattern.isEmpty else { return }
        filterHistory.removeAll { $0 == pattern }
        filterHistory.insert(pattern, at: 0)
        if filterHistory.count > 50 { filterHistory = Array(filterHistory.prefix(50)) }
        saveFilterHistory()
    }

    func clearFilterHistory() {
        filterHistory.removeAll()
        // Never write to the developer's real filter-history default under UI testing.
        guard !Self.isUITesting else { return }
        filterHistoryData = ""
    }

    func loadFilterHistory() {
        // Under UI testing, start from an EMPTY history and do not read the developer's
        // real saved filter history — so the tests neither display nor depend on it
        // (mirrors the session/recent-files/rules isolation). Combined with the
        // `saveFilterHistory` guard below, the developer's filter history on their own
        // machine is fully isolated from anything the UI tests type into the Filter box.
        guard !Self.isUITesting else { return }
        guard !filterHistoryData.isEmpty,
              let data = filterHistoryData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        filterHistory = decoded
    }

    func saveFilterHistory() {
        // Never persist filter-history changes under UI testing — filters the tests
        // type into the Filter box must not pollute the developer's real, saved
        // Filter history (mirrors the session/recent-files/rules guards).
        guard !Self.isUITesting else { return }
        if let data = try? JSONEncoder().encode(filterHistory),
           let string = String(data: data, encoding: .utf8) {
            filterHistoryData = string
        }
    }

}
