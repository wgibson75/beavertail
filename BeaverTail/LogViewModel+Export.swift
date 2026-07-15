import AppKit
import Foundation
import UniformTypeIdentifiers

extension LogViewModel {
    // MARK: - Export filtered lines

    /// Presents a save panel and writes every line currently shown in the filtered
    /// (bottom) pane to the chosen text file, preserving their original order. The
    /// lines are streamed to disk in batches so even very large match sets are
    /// exported without materialising the whole file in memory.
    func saveFilteredLinesToFile() {
        guard let tab = currentTab, tab.filterMessage == nil else {
            NSSound.beep()
            return
        }
        let provider = tab.filteredProvider
        let count = tab.filteredCount
        guard count > 0 else {
            NSSound.beep()
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.title = "Save Filtered Lines"
        panel.nameFieldStringValue = Self.suggestedFilteredExportName(for: tab)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task.detached(priority: .userInitiated) {
            Self.writeLines(from: provider, count: count, to: url)
        }
    }

    /// Suggests a default export filename derived from the tab's name, e.g.
    /// `server.log` → `server-filtered.txt`.
    nonisolated private static func suggestedFilteredExportName(for tab: LogTab) -> String {
        let base = (tab.name as NSString).deletingPathExtension
        let cleanBase = base.isEmpty ? "log" : base
        return "\(cleanBase)-filtered.txt"
    }

    /// Streams `count` lines from `provider` to `url`, batching writes so peak
    /// memory stays bounded regardless of how many lines matched the filter.
    nonisolated private static func writeLines(from provider: LineProvider, count: Int, to url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }

        let flushThreshold = 1 << 20 // ~1 MB
        var buffer = Data()
        buffer.reserveCapacity(flushThreshold + 4096)
        let newline = Data([0x0A])

        for i in 0..<count {
            buffer.append(Data(provider.line(at: i).utf8))
            buffer.append(newline)
            if buffer.count >= flushThreshold {
                try? handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try? handle.write(contentsOf: buffer)
        }
    }
}
