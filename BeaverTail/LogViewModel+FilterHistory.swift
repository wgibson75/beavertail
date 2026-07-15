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
        filterHistoryData = ""
    }

    func loadFilterHistory() {
        guard !filterHistoryData.isEmpty,
              let data = filterHistoryData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        filterHistory = decoded
    }

    func saveFilterHistory() {
        if let data = try? JSONEncoder().encode(filterHistory),
           let string = String(data: data, encoding: .utf8) {
            filterHistoryData = string
        }
    }

}
