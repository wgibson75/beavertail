//
//  LogViewModel.swift
//  BeaverTail
//
//  Created by William Gibson on 13/06/2026.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

// Direct notification channel descriptor driving top table viewport adjustments
let topPaneDirectScrollNotification = Notification.Name("BeaverTailTopPaneDirectScroll")

struct HighlightRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var pattern: String
    var foregroundColorHex: String
    var backgroundColorHex: String
    
    // Cached objects to ensure zero allocation inside rendering loops
    var nsForegroundColor: NSColor = .labelColor
    var nsBackgroundColor: NSColor = .clear
    var compiledRegex: NSRegularExpression? = nil
    
    var foregroundColor: Color { Color(hex: foregroundColorHex) ?? .black }
    var backgroundColor: Color { Color(hex: backgroundColorHex) ?? .yellow }
    
    enum CodingKeys: String, CodingKey {
        case id, pattern, foregroundColorHex, backgroundColorHex
    }
    
    init(id: UUID = UUID(), pattern: String, foregroundColorHex: String, backgroundColorHex: String) {
        self.id = id
        self.pattern = pattern
        self.foregroundColorHex = foregroundColorHex
        self.backgroundColorHex = backgroundColorHex
        self.updateCachedObjects()
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.pattern = try container.decode(String.self, forKey: .pattern)
        self.foregroundColorHex = try container.decode(String.self, forKey: .foregroundColorHex)
        self.backgroundColorHex = try container.decode(String.self, forKey: .backgroundColorHex)
        self.updateCachedObjects()
    }
    
    mutating func updateCachedObjects() {
        self.nsForegroundColor = NSColor(self.foregroundColor)
        self.nsBackgroundColor = NSColor(self.backgroundColor)
        self.compiledRegex = try? NSRegularExpression(pattern: self.pattern, options: [])
    }
    
    static func == (lhs: HighlightRule, rhs: HighlightRule) -> Bool {
        return lhs.id == rhs.id && lhs.pattern == rhs.pattern &&
               lhs.foregroundColorHex == rhs.foregroundColorHex && lhs.backgroundColorHex == rhs.backgroundColorHex
    }
}

// Explicit line wrapper that locks text to its original file position index
struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let originalIndex: Int
    let text: String
}

class LogViewModel: ObservableObject {
    @Published var allLines: [String] = []
    @Published var filteredLines: [LogLine] = []
    @Published var isFiltering: Bool = false
    @Published var filterProgress: Double = 0.0
    @Published var showMinimap: Bool = true
    @Published var isCaseInsensitive: Bool = true
    @Published var isScrubbingMinimap: Bool = false // Tracks if the minimap gesture is actively running
    
    // Proportional decimal state indicating selection placement
    @Published var selectedFraction: CGFloat? = nil
    
    // Fully compiled flat image layer token rendering target context
    @Published var minimapImage: NSImage? = nil
    
    @AppStorage("saved_highlight_rules") private var rulesData: String = ""
    @Published var highlightRules: [HighlightRule] = [] {
        didSet {
            saveRules()
            generateMinimapData() // Regenerate data when highlight criteria change
        }
    }
    
    private var filterTask: Task<Void, Never>?
    private var minimapTask: Task<Void, Never>?
    
    init() {
        loadRules()
    }
    
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text, .log, .plainText]
        
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(from: url)
        }
    }
    
    @MainActor
    private func loadFile(from url: URL) {
        do {
            let data = try String(contentsOf: url, encoding: .utf8)
            self.allLines = data.components(separatedBy: .newlines)
            self.filteredLines = []
            self.selectedFraction = nil // Clear cursor tracking line automatically on new file load
            self.minimapImage = nil
            
            generateMinimapData() // Generate map data immediately upon file load
        } catch {
            self.allLines = ["Error loading file: \(error.localizedDescription)"]
            self.filteredLines = []
            self.minimapImage = nil
        }
    }
    
    func applyFilter(with pattern: String) {
        filterTask?.cancel()
        
        guard !pattern.isEmpty else {
            self.filteredLines = []
            self.isFiltering = false
            return
        }
        
        let regexOptions: NSRegularExpression.Options = isCaseInsensitive ? [.caseInsensitive] : []
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else {
            self.filteredLines = [LogLine(originalIndex: 0, text: "Invalid Regular Expression")]
            return
        }
        
        isFiltering = true
        filterProgress = 0.0
        
        let localLinesSnapshot = self.allLines
        
        filterTask = Task(priority: .userInitiated) {
            var matched: [LogLine] = []
            let totalLines = localLinesSnapshot.count
            let chunkSize = max(1, totalLines / 100)
            
            for (index, line) in localLinesSnapshot.enumerated() {
                if Task.isCancelled { return }
                
                let range = NSRange(location: 0, length: line.utf16.count)
                if regex.firstMatch(in: line, options: [], range: range) != nil {
                    // Lock the exact index alongside the text string snapshot frame
                    matched.append(LogLine(originalIndex: index, text: line))
                }
                
                if index % chunkSize == 0 || index == totalLines - 1 {
                    let progress = Double(index + 1) / Double(totalLines)
                    await MainActor.run {
                        self.filterProgress = progress
                    }
                }
            }
            
            if !Task.isCancelled {
                await MainActor.run {
                    self.filteredLines = matched
                    self.isFiltering = false
                }
            }
        }
    }

    // HIG-COMPLIANT BACKGROUND BITMAP GENERATION CONTEXT
    func generateMinimapData() {
        minimapTask?.cancel()
        
        let localLines = self.allLines
        let activeRules = self.highlightRules.filter { $0.compiledRegex != nil }
        
        guard !localLines.isEmpty && !activeRules.isEmpty else {
            self.minimapImage = nil
            return
        }
        
        minimapTask = Task(priority: .userInitiated) {
            let totalLines = localLines.count
            let imgSize = NSSize(width: 30, height: 1500)
            
            // THE AMENDMENT: Set flipped to true so line index 0 is rendered at the top of the image buffer
            let bitmap = NSImage(size: imgSize, flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                context.fill(rect)
                
                var paintedBuckets = Set<Int>()
                
                for (index, line) in localLines.enumerated() {
                    if Task.isCancelled { return false }
                    
                    let bucket = Int((CGFloat(index) / CGFloat(totalLines)) * 1500.0)
                    if paintedBuckets.contains(bucket) { continue }
                    
                    let range = NSRange(location: 0, length: line.utf16.count)
                    for rule in activeRules {
                        if let regex = rule.compiledRegex {
                            if regex.firstMatch(in: line, options: [], range: range) != nil {
                                paintedBuckets.insert(bucket)
                                
                                context.setFillColor(rule.nsBackgroundColor.cgColor)
                                context.fill(CGRect(x: 0, y: CGFloat(bucket), width: 30, height: 1.5))
                                break
                            }
                        }
                    }
                }
                return true
            }
            
            if !Task.isCancelled {
                await MainActor.run {
                    self.minimapImage = bitmap
                }
            }
        }
    }
    
    func syncSelectionFromFilteredIndex(_ originalIndex: Int) {
        guard !allLines.isEmpty else { return }
        
        // 1. Position the minimap indicator bar exactly at the target index percentage
        let fraction = CGFloat(originalIndex) / CGFloat(allLines.count - 1)
        self.selectedFraction = max(0, min(1, fraction))
        
        // 2. Direct event dispatch bypassing all string lookups and duplication bugs completely
        NotificationCenter.default.post(name: topPaneDirectScrollNotification, object: originalIndex)
    }
    
    func jumpToFraction(_ fraction: CGFloat) {
        self.isScrubbingMinimap = true // Engages the minimap lock
        self.selectedFraction = max(0, min(1, fraction))
    }

    func updateFractionFromScroll(_ fraction: CGFloat) {
        // Only update the selection line position if the value is a valid change
        let sanitized = max(0, min(1, fraction))
        if self.selectedFraction != sanitized {
            self.selectedFraction = sanitized
        }
    }

    func updateMinimapFromLineIndex(_ index: Int) {
        guard !allLines.isEmpty else { return }
        let fraction = CGFloat(index) / CGFloat(allLines.count - 1)
        self.selectedFraction = max(0, min(1, fraction))
    }
    
    private func saveRules() {
        if let encoded = try? JSONEncoder().encode(highlightRules),
           let string = String(data: encoded, encoding: .utf8) {
            if rulesData != string { rulesData = string }
        }
    }
    
    private func loadRules() {
        guard !rulesData.isEmpty,
              let data = rulesData.data(using: .utf8),
              var decoded = try? JSONDecoder().decode([HighlightRule].self, from: data) else { return }
        
        for i in 0..<decoded.count {
            decoded[i].updateCachedObjects()
        }
        self.highlightRules = decoded
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        self.init(red: Double((rgb & 0xFF0000) >> 16) / 255.0,
                  green: Double((rgb & 0x00FF00) >> 8) / 255.0,
                  blue: Double(rgb & 0x0000FF) / 255.0)
    }
    
    func toHex() -> String {
        // Fall back to target hex mapping manually without casting conflicts
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components, components.count >= 3 else {
            return "000000"
        }
        
        // Extract directly as native CGFloat array elements
        let r: CGFloat = components[0]
        let g: CGFloat = components[1]
        let b: CGFloat = components[2]
        
        // Convert to standard 0-255 Integer values using integer rounding multiplication math
        let rInt = Int(clamping: lround(Double(r * 255.0)))
        let gInt = Int(clamping: lround(Double(g * 255.0)))
        let bInt = Int(clamping: lround(Double(b * 255.0)))
        
        return String(format: "%02X%02X%02X", rInt, gInt, bInt)
    }
}
