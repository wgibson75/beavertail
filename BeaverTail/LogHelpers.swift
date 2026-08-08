//
//  LogHelpers.swift
//  BeaverTail
//

import SwiftUI
import AppKit
import Combine

// MARK: - Recent File Model

struct RecentFile: Codable, Identifiable {
    var id: String { bookmarkBase64 }
    let name: String
    let bookmarkBase64: String
}

// MARK: - Color Helpers

extension Color {
    nonisolated init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }

    func toHex() -> String {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components, components.count >= 3 else { return "000000" }
        let rInt = Int(clamping: lround(Double(components[0] * 255.0)))
        let gInt = Int(clamping: lround(Double(components[1] * 255.0)))
        let bInt = Int(clamping: lround(Double(components[2] * 255.0)))
        return String(format: "%02X%02X%02X", rInt, gInt, bInt)
    }
}

class LogProgressTracker: ObservableObject {
    @Published var isLoadingFile: Bool = false
    @Published var fileLoadProgress: Double = 0.0
    @Published var isFiltering: Bool = false
    @Published var filterProgress: Double = 0.0
    /// Drives the "Generating unique lines…" progress bar while the good/bad log
    /// comparison runs.
    @Published var isComparing: Bool = false
    @Published var compareProgress: Double = 0.0
}

class RecentFilesTracker: ObservableObject {
    static let shared = RecentFilesTracker()
    @Published var recentFiles: [RecentFile] = []
}

/// Rarely-changing state that drives menu-command availability. Kept separate from
/// `LogViewModel` (which the App holds via `@State`, deliberately unobserved to avoid
/// redrawing the menus on every frequent `@Published` update) so menu items can react
/// to it. Its published values are only reassigned when they actually change, so the
/// menus rebuild only on genuine transitions.
class AppCommandState: ObservableObject {
    static let shared = AppCommandState()
    /// True only while the unsaved "unique lines" results tab is the selected tab.
    @Published var canSaveUniqueLines: Bool = false
}
