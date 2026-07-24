//
//  FileExportService.swift
//  BeaverTail
//
//  Service layer: pure file-writing logic extracted from the LogViewModel so
//  the view model only orchestrates (show a save panel, hand off work) while
//  the actual disk I/O lives in one testable, UI-free place.
//

import Foundation

/// Streams log lines to disk. Deliberately free of any AppKit / SwiftUI or
/// view-model state so it can be unit-tested and reused.
enum FileExportService {

    /// Suggests a default export filename derived from a tab's name, e.g.
    /// `server.log` → `server-filtered.txt`.
    static func suggestedFilteredExportName(forTabNamed name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let cleanBase = base.isEmpty ? "log" : base
        return "\(cleanBase)-filtered.txt"
    }

    /// Streams `count` lines from `provider` to `url`, batching writes so peak
    /// memory stays bounded regardless of how many lines matched the filter.
    /// `nonisolated` so it can run on a background task rather than the main actor.
    nonisolated static func writeLines(from provider: LineProvider, count: Int, to url: URL) {
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
