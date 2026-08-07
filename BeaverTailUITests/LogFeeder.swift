//
//  LogFeeder.swift
//  BeaverTailUITests
//
//  Streams log data into a file to exercise BeaverTail's live-tailing (Follow) while
//  a UI test observes the minimap / Timeline updating. This is a self-contained Swift
//  port of `scripts/writelog.py`: it uses the same word pool, the same line format
//  (`[timestamp] Sentence.`) and the same 1-second-window rate limiting, so the tests
//  do not depend on an external Python runtime. It additionally supports injecting
//  "marker" lines that are guaranteed to contain a given token, so a test can make a
//  specific highlight filter start matching at a controlled moment (letting the
//  Timeline's heading count grow deterministically).
//
//  All writes go through one lock, so the background volume stream and the test's
//  marker injections can safely interleave on the same file handle.
//

import Foundation

final class LogFeeder {

    /// Same pool as `scripts/writelog.py`.
    private static let words = [
        "info", "warning", "error", "critical", "database", "connection", "timeout",
        "user", "login", "success", "failed", "request", "processed", "response",
        "gateway", "server", "cluster", "memory", "cpu", "utilization", "high",
        "thread", "pool", "exhausted", "retrying", "transaction", "committed"
    ]

    private let fileURL: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var running = false
    private var thread: Thread?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Begins streaming random lines at approximately `bytesPerSecond` (capped at the
    /// tests' target of 250 KB/s). Returns immediately; streaming runs on a background
    /// thread until `stop()`/`stopVolumeStream()` is called, or — if `maxLines` is given
    /// — until that many volume lines have been written (whichever comes first). Capping
    /// the volume keeps a test's log at a known, small size regardless of how long the
    /// (snapshot-latency-bound) probe waits take, so line indices and the accessibility
    /// tree stay predictable.
    func start(bytesPerSecond: Int, maxLines: Int? = nil) {
        lock.lock()
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        running = true
        lock.unlock()

        let rate = max(1, min(bytesPerSecond, 250 * 1024))
        let thread = Thread { [weak self] in
            self?.streamLoop(bytesPerSecond: rate, maxLines: maxLines)
        }
        thread.name = "uitest.logfeeder"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    /// Appends a single line guaranteed to contain `token`, so a highlight filter
    /// whose pattern is `token` will match it. Thread-safe against the volume stream,
    /// and works whether or not the volume stream is currently running (it reopens the
    /// file handle if `stopVolumeStream()` left it open but the loop has ended, or if
    /// the handle was never opened).
    func emitLineContaining(_ token: String) {
        let line = "\(Self.timestamp()) MARKER \(token) event\n"
        write(Data(line.utf8))
    }

    /// Stops the background volume stream but KEEPS the file handle open, so the test
    /// can continue to inject `emitLineContaining` markers into the same file while the
    /// app tails it. This is how the Timeline test proves ingestion under load with a
    /// short burst and then quiesces the flood — keeping the log (and hence the
    /// accessibility tree the test must query) small so probe reads and element lookups
    /// stay fast and the per-marker assertions don't time out.
    func stopVolumeStream() {
        lock.lock()
        running = false
        lock.unlock()
        // Wait for the streaming thread to actually exit before returning, so NO further
        // volume lines are written after this call. The caller can then inject marker
        // lines knowing they will be the last lines in the file (which the minimap
        // region/click tests rely on to land a click deterministically on the markers).
        let deadline = Date().addingTimeInterval(2.0)
        while !(thread?.isFinished ?? true) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// Stops streaming and closes the file handle.
    func stop() {
        lock.lock()
        running = false
        let handleToClose = handle
        handle = nil
        lock.unlock()
        try? handleToClose?.close()
    }

    // MARK: - Internals

    private func streamLoop(bytesPerSecond: Int, maxLines: Int?) {
        var windowStart = Date()
        var bytesInWindow = 0
        var linesWritten = 0

        while true {
            lock.lock()
            let isRunning = running
            lock.unlock()
            guard isRunning else { break }
            // Self-terminate once the requested number of volume lines has been written.
            if let maxLines, linesWritten >= maxLines { break }

            let line = Self.randomLine()
            let data = Data(line.utf8)

            // Rate limiting, mirroring writelog.py: keep a 1-second accounting window
            // and sleep the fractional difference so the average byte rate is held.
            let now = Date()
            var elapsed = now.timeIntervalSince(windowStart)
            if elapsed >= 1.0 {
                windowStart = now
                bytesInWindow = 0
                elapsed = 0
            }
            let expected = Double(bytesInWindow + data.count) / Double(bytesPerSecond)
            if elapsed < expected {
                Thread.sleep(forTimeInterval: expected - elapsed)
            }

            write(data)
            bytesInWindow += data.count
            linesWritten += 1
        }
    }

    private func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let handle {
            handle.write(data)
        } else if let reopened = try? FileHandle(forWritingTo: fileURL) {
            // The volume stream was fully stopped (handle closed): append via a
            // short-lived handle so marker injection still reaches the tailed file.
            reopened.seekToEndOfFile()
            reopened.write(data)
            try? reopened.close()
        }
    }

    private static func randomLine() -> String {
        let count = Int.random(in: 5...12)
        let sentence = (0..<count).map { _ in words.randomElement() ?? "info" }
            .joined(separator: " ")
        return "\(timestamp()) \(sentence.capitalizedFirst).\n"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "[yyyy-MM-dd HH:mm:ss]"
        return formatter.string(from: Date())
    }
}

private extension String {
    /// Capitalises only the first character (matching Python's `str.capitalize()`
    /// closely enough for log content), leaving the rest untouched.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
