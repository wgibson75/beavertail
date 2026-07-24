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
        panel.nameFieldStringValue = FileExportService.suggestedFilteredExportName(forTabNamed: tab.name)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Hand the disk I/O off to the service layer — the view model only
        // orchestrates the user-facing save panel.
        Task.detached(priority: .userInitiated) {
            FileExportService.writeLines(from: provider, count: count, to: url)
        }
    }
}
