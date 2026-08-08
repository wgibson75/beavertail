//
//  LiveTailService.swift
//  BeaverTail
//
//  Service layer: the file-monitoring state machine that powers live tailing
//  (Follow). The view model previously polled the file, tracked the last-known
//  size / remainder bytes, and decoded new lines inline via `FileHandle` /
//  `FileManager`. That I/O + byte-splitting logic now lives here, behind a small
//  value-typed event API, so it is UI-free and can be unit-tested against real
//  temp files without a running app. `LogViewModel+LiveTailing` keeps only the
//  orchestration: it drives the poll loop and applies each event to tab state on
//  the main actor.
//

import Foundation

/// The outcome of one polling step of a live-tail file monitor.
enum LiveTailEvent: Equatable {
    /// Nothing to do this tick: the file is unchanged, or grew but not yet by a
    /// complete (newline-terminated) line.
    case noChange
    /// The file could not be read and had previously been present — it was most
    /// likely deleted or moved. Emitted once per disappearance.
    case fileDisappeared
    /// The file shrank, or reappeared after having been deleted — it must be
    /// re-read from scratch (log rotation / truncation / recreation).
    case reset
    /// One or more complete new lines were read from the end of the file.
    case appended(lines: [String])
}

/// Pure, UI-free helpers for live tailing.
enum LiveTailService {
    /// Default upper bound on how many bytes a single poll reads, so a huge jump
    /// in file size can't allocate an unbounded buffer in one tick.
    nonisolated static let defaultMaxReadChunk: UInt64 = 50 * 1024 * 1024

    /// Splits freshly-read bytes (appended to any leftover `remainder` from the
    /// previous read) into complete lines plus the new remainder — the bytes after
    /// the last newline, which belong to a line that hasn't fully arrived yet.
    ///
    /// Splitting uses the `.newlines` character set and a trailing empty component
    /// (from the final newline) is dropped — behaviour preserved verbatim from the
    /// original inline live-tail decoder. When the data contains no newline at all,
    /// no lines are returned and everything becomes the remainder.
    nonisolated static func extractCompleteLines(
        appending newData: Data,
        to remainder: Data
    ) -> (lines: [String], remainder: Data) {
        var dataToProcess = remainder
        dataToProcess.append(newData)

        guard let lastNewline = dataToProcess.lastIndex(of: 0x0A) else {
            // No complete line yet — hold everything for the next read.
            return ([], dataToProcess)
        }

        let completeData = dataToProcess.prefix(upTo: lastNewline + 1)
        let newRemainder = Data(dataToProcess.suffix(from: lastNewline + 1))

        let text = String(decoding: completeData, as: UTF8.self)
        var linesArray = text
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\r", with: "") }
        if linesArray.last?.isEmpty == true { linesArray.removeLast() }

        return (linesArray, newRemainder)
    }
}

/// A stateful monitor for a single file, tracking the last-known size, whether the
/// file was present, and any partial-line remainder. Each `poll()` inspects the
/// file and returns a `LiveTailEvent` describing what changed, advancing its
/// internal state. It owns the only `FileHandle` / `FileManager` usage in the
/// live-tailing path.
///
/// Instances are used entirely within a single detached task (created and polled
/// there), so no cross-actor sharing occurs.
nonisolated final class LiveTailFileMonitor {
    private let fileURL: URL
    private let maxReadChunk: UInt64

    private var lastKnownSize: UInt64
    private var wasFilePresent: Bool
    private var remainderData = Data()

    /// - Parameters:
    ///   - fileURL: The file to monitor.
    ///   - hasInitialContent: Whether the tab already holds in-memory content. Used
    ///     only to decide the starting "present" state when the file can't be
    ///     stat'd at creation (so a not-yet-created file with loaded content is
    ///     treated as absent and will trigger a reset once it appears).
    ///   - maxReadChunk: Upper bound on bytes read per poll.
    init(
        fileURL: URL,
        hasInitialContent: Bool,
        maxReadChunk: UInt64 = LiveTailService.defaultMaxReadChunk
    ) {
        self.fileURL = fileURL
        self.maxReadChunk = maxReadChunk

        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? UInt64 {
            self.lastKnownSize = size
            self.wasFilePresent = true
        } else {
            self.lastKnownSize = 0
            self.wasFilePresent = hasInitialContent
        }
    }

    /// Inspects the file once and returns what changed since the previous poll,
    /// updating the monitor's state accordingly.
    func poll() -> LiveTailEvent {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let currentSize = attributes[.size] as? UInt64 else {
            // File may be deleted or moved.
            if wasFilePresent {
                wasFilePresent = false
                lastKnownSize = 0
                remainderData = Data()
                return .fileDisappeared
            }
            return .noChange
        }

        if currentSize < lastKnownSize || !wasFilePresent {
            // Log rotated or truncated, OR re-created/written to after being deleted.
            // The whole file must be re-read; the caller resets and reloads the tab.
            lastKnownSize = 0
            remainderData = Data()
            wasFilePresent = true
            return .reset
        }

        guard currentSize > lastKnownSize else { return .noChange }

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return .noChange }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: lastKnownSize)
            let bytesToRead = currentSize - lastKnownSize
            let readCount = min(bytesToRead, maxReadChunk)
            guard let newData = try fileHandle.read(upToCount: Int(readCount)), !newData.isEmpty else {
                return .noChange
            }
            lastKnownSize += UInt64(newData.count)

            let (lines, newRemainder) = LiveTailService.extractCompleteLines(
                appending: newData, to: remainderData
            )
            remainderData = newRemainder
            return lines.isEmpty ? .noChange : .appended(lines: lines)
        } catch {
            return .noChange
        }
    }
}
