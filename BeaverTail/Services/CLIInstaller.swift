//
//  CLIInstaller.swift
//  BeaverTail
//
//  Service layer: installs the `btail` command-line helper. Extracted out of
//  BeaverTailApp.swift so the App/AppDelegate layer stays focused on scene &
//  lifecycle wiring instead of shell-script + filesystem work.
//

import AppKit
import Darwin
import Foundation

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

/// Writes the btail shell script to /usr/local/bin/btail (or ~/.local/bin) so
/// the app can be launched from the command line.
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
