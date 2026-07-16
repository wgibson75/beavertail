//
//  BeaverTailApp.swift
//  BeaverTail
//

import AppKit
import Darwin
import SwiftUI
import Carbon

/// Notification fired from the File menu so the view model can open a file.
let openFileMenuNotification = Notification.Name("BeaverTailOpenFileMenu")
let showHelpNotification = Notification.Name("BeaverTailShowHelp")
/// Notification fired when the app is asked to open a specific file URL (e.g. via btail CLI).
let openFileURLNotification = Notification.Name("BeaverTailOpenFileURL")

/// Identifier for the standalone, resizable/movable Highlight Filters window.
let highlightFiltersWindowID = "highlight-filters"

// MARK: - AppDelegate (handles file-open events from the OS / btail CLI)

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for kAEOpenDocuments Apple Events — this fires reliably
        // when `open -a BeaverTail file.log` is used, both on fresh launch
        // and when the app is already running.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )

        // Handle files passed as raw command-line arguments (e.g. when Xcode
        // or a wrapper launches the binary directly with a path argument).
        let args = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in args {
            NotificationCenter.default.post(name: openFileURLNotification, object: url)
        }

        // Check GitHub for a newer release (unless the user has disabled it).
        // Delayed slightly so the main window is on screen before any alert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            UpdateChecker.checkAutomatically()
        }
    }

    @objc func handleOpenDocumentsEvent(
        _ event: NSAppleEventDescriptor,
        replyEvent: NSAppleEventDescriptor
    ) {
        guard let fileList = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        else { return }

        let count = fileList.numberOfItems
        if count == 0 {
            // Single item — not a list descriptor
            if let urlString = fileList.stringValue,
               let url = URL(string: urlString) ?? URL(string: "file://" + urlString) {
                NotificationCenter.default.post(name: openFileURLNotification, object: url)
            }
        } else {
            for idx in 1...count {
                guard let item = fileList.atIndex(idx),
                      let urlString = item.stringValue else { continue }
                let url = URL(string: urlString) ?? URL(fileURLWithPath: urlString)
                NotificationCenter.default.post(name: openFileURLNotification, object: url)
            }
        }
        Self.forceFocus()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: openFileURLNotification, object: url)
        }
        Self.forceFocus()
    }

    static func forceFocus() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .filter { $0.canBecomeMain }
                .forEach { $0.makeKeyAndOrderFront(nil) }
            NSApplication.shared.activate()
        }
        // Second attempt after a short delay covers the case where the window
        // needs a run-loop cycle to become ready after a fresh launch with a file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .filter { $0.canBecomeMain }
                .forEach { $0.makeKeyAndOrderFront(nil) }
            NSApplication.shared.activate()
        }
    }
}

// MARK: - CLI installer helper

/// Returns the real (non-sandboxed) home directory by querying the passwd
/// database directly. NSHomeDirectory() / FileManager.homeDirectoryForCurrentUser
/// both return the sandbox container path when the app is sandboxed.
private func realHomeDirectory() -> String {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return String(cString: dir)
    }
    // Fallback: strip the sandbox container suffix from NSHomeDirectory()
    let sandboxed = NSHomeDirectory()
    if let range = sandboxed.range(of: "/Library/Containers/") {
        return String(sandboxed[..<range.lowerBound])
    }
    return sandboxed
}

/// Writes the btail shell script to /usr/local/bin/btail using an
/// AuthorizationRef so it works even when that directory is root-owned.
enum BTailInstaller {
    /// Preferred install location — always user-writable, no admin needed.
    static var installPath: String { "\(realHomeDirectory())/.local/bin/btail" }
    /// Fallback location tried first if it already exists and is writable.
    static let systemInstallPath = "/usr/local/bin/btail"

    /// Returns the shell script text, embedding the current app bundle path so
    /// `open -a` always resolves to this exact BeaverTail installation.
    static func scriptContent() -> String {
        let appPath = Bundle.main.bundlePath
        return """
        #!/bin/sh
        # btail – open BeaverTail from the command line
        # Installed by BeaverTail. Re-run "Install btail CLI" to update.
        if [ "$#" -eq 0 ]; then
            open -a "\(appPath)"
        else
            for f in "$@"; do
                abs=$(cd "$(dirname "$f")" 2>/dev/null && pwd)/$(basename "$f")
                open -a "\(appPath)" "$abs"
            done
            # Wait for the app to process the file before activating.
            # The terminal briefly regains focus after open returns; this
            # ensures BeaverTail wins focus back after it has settled.
            sleep 0.2
            open -a "\(appPath)"
        fi
        """
    }

    /// Installs (or updates) the btail script — no admin rights required.
    /// Installs to /usr/local/bin if already writable, otherwise ~/.local/bin.
    @MainActor
    static func install() {
        let script = scriptContent()

        // ── Try /usr/local/bin first if it is already writable ───────────────
        let systemDir = URL(fileURLWithPath: systemInstallPath)
            .deletingLastPathComponent().path
        if FileManager.default.isWritableFile(atPath: systemDir) {
            if writeScript(script, to: systemInstallPath) {
                lsRegister()
                showSuccess(at: systemInstallPath)
                return
            }
        }

        // ── Install to ~/.local/bin (always user-writable, no admin needed) ──
        let userBinDir = URL(fileURLWithPath: installPath)
            .deletingLastPathComponent().path
        do {
            try FileManager.default.createDirectory(
                atPath: userBinDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            showAlert(
                title: "Install Failed",
                message: "Could not create \(userBinDir):\n\(error.localizedDescription)"
            )
            return
        }

        if writeScript(script, to: installPath) {
            // Force-register the app with Launch Services so macOS immediately
            // knows to route file-open requests to BeaverTail via open -a.
            lsRegister()
            showSuccess(at: installPath)
        } else {
            showAlert(
                title: "Install Failed",
                message: "Could not write to \(installPath).\n" +
                         "Please check permissions on \(userBinDir)."
            )
        }
    }

    /// Re-registers the app bundle with macOS Launch Services so that
    /// document type and URL scheme associations take effect immediately
    /// without requiring the user to manually launch the app first.
    private static func lsRegister() {
        let lsregister =
            "/System/Library/Frameworks/CoreServices.framework" +
            "/Versions/A/Frameworks/LaunchServices.framework" +
            "/Versions/A/Support/lsregister"
        runShell(lsregister, args: ["-f", Bundle.main.bundlePath])
    }

    // MARK: Private helpers

    /// Writes the script and sets the executable bit. Returns true on success.
    @discardableResult
    private static func writeScript(_ content: String, to path: String) -> Bool {
        guard (try? content.write(toFile: path, atomically: true, encoding: .utf8)) != nil
        else { return false }
        runShell("/bin/chmod", args: ["+x", path])
        return true
    }

    private static func showSuccess(at path: String) {
        let binDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let pathHint = binDir == "\(realHomeDirectory())/.local/bin"
            ? "~/.local/bin is not in PATH by default on all shells.\n" +
              "Add this line to your ~/.zshrc (or ~/.bashrc):\n\n" +
              "  export PATH=\"$HOME/.local/bin:$PATH\""
            : "\(binDir) should already be in your shell's PATH."
        showAlert(
            title: "btail Installed",
            message: "btail has been installed to \(path).\n\n" +
                     "Usage:  btail [file …]\n\n" +
                     pathHint
        )
    }

    @discardableResult
    private static func runShell(_ launchPath: String, args: [String]) -> Int32 {
        let proc = Process()
        proc.launchPath = launchPath
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.launch()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@main
struct BeaverTailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Using @State instead of @StateObject prevents the entire App menu from redrawing
    // whenever LogViewModel `@Published` properties (like openTabs) are repeatedly
    // updated during file loading, regex filtering, and minimap rendering.
    @State private var viewModel = LogViewModel()
    @StateObject private var recentTracker = RecentFilesTracker.shared

    /// Whether BeaverTail checks GitHub for a newer release on launch.
    /// Defaults to on; the user can disable it from the app menu.
    @AppStorage(UpdateChecker.autoCheckDefaultsKey) private var autoCheckForUpdates = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onReceive(NotificationCenter.default.publisher(for: openFileURLNotification)) { note in
                    guard let url = note.object as? URL else { return }
                    viewModel.loadNewTab(from: url)
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            // Add "Install btail CLI" into the system BeaverTail app menu,
            // above the standard "Hide BeaverTail" item.
            CommandGroup(before: .appVisibility) {
                Button("Install btail CLI") {
                    BTailInstaller.install()
                }
                Divider()
                Button("Check for Updates…") {
                    UpdateChecker.checkManually()
                }
                Toggle("Check for Updates Automatically", isOn: $autoCheckForUpdates)
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: openFileMenuNotification, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    if recentTracker.recentFiles.isEmpty {
                        Text("No Recent Files")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentTracker.recentFiles) { recent in
                            Button(recent.name) {
                                viewModel.openRecentFile(recent)
                            }
                        }
                        Divider()
                        Button("Clear Recent Files") {
                            viewModel.clearRecentFiles()
                        }
                    }
                }
            }
            CommandGroup(replacing: .help) {
                Button("BeaverTail Help") {
                    NotificationCenter.default.post(name: showHelpNotification, object: nil)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // Standalone Highlight Filters window. As a SwiftUI `Window` scene it is
        // freely movable and resizable, and SwiftUI automatically persists its size
        // and position across launches (keyed by the scene id).
        Window("Highlight Filters", id: highlightFiltersWindowID) {
            HighlightSettingsView(viewModel: viewModel)
                .onAppear { viewModel.isHighlightWindowOpen = true }
                .onDisappear { viewModel.isHighlightWindowOpen = false }
        }
        .defaultSize(width: 540, height: 460)
        .windowResizability(.contentMinSize)
    }
}
