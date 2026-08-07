//
//  UITestSupport.swift
//  BeaverTailUITests
//
//  Shared helpers for BeaverTail UI tests. These are black-box tests: they launch
//  the real app (with the `-uitesting` flag so it starts from a clean, hermetic
//  state) and drive it via the accessibility hierarchy — no `@testable import`.
//

import XCTest

class BeaverTailUITestCase: XCTestCase {

    /// Temp log files created for a test, removed in `tearDown`.
    private var tempURLs: [URL] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        for url in tempURLs { try? FileManager.default.removeItem(at: url) }
        tempURLs = []
        super.tearDown()
    }

    /// Writes a temporary `.log` file and tracks it for cleanup.
    @discardableResult
    func makeTempLog(_ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-\(UUID().uuidString).log")
        try? contents.data(using: .utf8)?.write(to: url)
        tempURLs.append(url)
        return url
    }

    // MARK: - Launch

    /// Launches the app under UI-testing mode, optionally opening files (passed as
    /// path arguments, which `AppDelegate` opens on launch) and pinning the view
    /// preferences the tailing tests care about.
    ///
    /// `@AppStorage` reads the developer's real `UserDefaults`, which `-uitesting`
    /// does not reset — so view preferences (Timeline, Minimap, …) and, crucially,
    /// the developer's own **highlight filters** would otherwise leak into the tests.
    /// We pin every value we depend on via the UserDefaults *argument domain*
    /// (`-key value` pairs that apply to this launch only and are never persisted),
    /// so the tests are fully self-contained and the developer's real settings and
    /// highlight filters are left untouched.
    ///
    /// Note: override values must not be an empty string — the app treats bare
    /// (non-`-`) arguments as file paths to open, and `""` resolves to the current
    /// directory (which exists), spuriously leaving the empty state. The values used
    /// here ("NO"/"YES"/"12"/JSON) don't resolve to existing files, so they're safe.
    @discardableResult
    func launchApp(
        openingFiles files: [URL] = [],
        showMinimap: Bool = false,
        showTimeline: Bool = false,
        highlightRules: [HighlightFilterSpec] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        var args =
            ["-uitesting",
             "-saved_show_timeline", showTimeline ? "YES" : "NO",
             "-saved_show_minimap", showMinimap ? "YES" : "NO",
             "-saved_show_line_numbers", "NO",
             "-saved_show_timestamp_bubble", "NO",
             "-saved_bottom_pane_horizontal_scroll", "NO",
             "-saved_font_size", "12"]
        if !highlightRules.isEmpty {
            // Inject a self-contained highlight filter set via a temp JSON file (the
            // app loads it under `-uitesting`). A file + single `-key=value` token is
            // used rather than `-saved_highlight_rules <json>` because the UserDefaults
            // argument domain mis-handles a value starting with `[`, silently falling
            // back to the developer's real saved filters. Groups are omitted, so every
            // filter is ungrouped and active.
            let rulesURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("uitest-rules-\(UUID().uuidString).json")
            try? HighlightFilterSpec.json(for: highlightRules).data(using: .utf8)?.write(to: rulesURL)
            tempURLs.append(rulesURL)
            args += ["-uitest_highlight_rules_path=\(rulesURL.path)"]
        }
        args += files.map { $0.path }
        app.launchArguments = args
        app.launch()
        bringToForeground(app)
        return app
    }

    /// Brings the app to the foreground and verifies it actually presents a window,
    /// failing fast with an actionable message if it doesn't.
    ///
    /// macOS UI tests drive the real window server, so they only work on an unlocked,
    /// on-console GUI session with Automation/Accessibility permission granted to the
    /// test runner. When that isn't the case the *menu bar* is still reachable (the
    /// system draws it), but the app's own window never appears. Without this check
    /// that surfaces as a confusing timeout deep inside a test; with it, the very
    /// first assertion explains what to fix.
    ///
    /// Note: on macOS 26.x, SwiftUI's `WindowGroup` can fail to present a window
    /// under XCUITest; the app installs an AppKit fallback window under `-uitesting`
    /// to guarantee a window regardless. If this assertion ever fails it therefore
    /// points at the host/session, not the app.
    func bringToForeground(_ app: XCUIApplication) {
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15),
            "BeaverTail did not reach the foreground. macOS UI tests require an "
            + "UNLOCKED, on-console GUI session (not SSH/headless/locked) with "
            + "Automation & Accessibility permission granted to the test runner in "
            + "System Settings ▸ Privacy & Security.")
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
            "BeaverTail is in the foreground but presented no window (macOS: \(os)). "
            + "Run the tests at the machine on an UNLOCKED, on-console GUI session "
            + "(not Screen Sharing/SSH/clamshell), with the display awake and "
            + "Automation & Accessibility granted to the test runner.")
    }

    // MARK: - Element lookup

    /// Locates an element by accessibility identifier without assuming a concrete
    /// element type. SwiftUI does not always expose controls under the type you'd
    /// expect (e.g. a bordered-prominent `Button` may not surface as `.buttons`), so
    /// a type-agnostic query is the reliable way to find them.
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    // MARK: - Interactions

    /// Enables Follow (live-tail) by clicking the toolbar toggle.
    func enableFollow(in app: XCUIApplication) {
        let toggle = element("followToggle", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "The Follow toggle should exist.")
        if !isOn(toggle) { toggle.click() }
    }

    /// Types a regex into the Filter field and submits it, applying the filter.
    func applyFilter(_ pattern: String, in app: XCUIApplication) {
        let field = app.textFields["filterField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The Filter field should exist.")
        field.click()
        // Clear any existing text, then type the new pattern and submit with Return.
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(pattern + "\r")
    }

    // MARK: - Minimap interactions

    /// The minimap strip, located by its accessibility identifier.
    func minimap(in app: XCUIApplication) -> XCUIElement {
        element("logMinimap", in: app)
    }

    /// Marks out a time period on the minimap by dragging from `fromFraction` to
    /// `toFraction` (0...1 of the minimap height). This is the click-drag-release
    /// gesture that narrows the visible range (see `selectTimePeriod`).
    func selectMinimapRegion(
        fromFraction: CGFloat, toFraction: CGFloat, in app: XCUIApplication
    ) {
        let strip = minimap(in: app)
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "The minimap should exist.")
        let start = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromFraction))
        let end = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toFraction))
        start.press(forDuration: 0.2, thenDragTo: end)
    }

    /// Clicks a single entry on the minimap at `fraction` (0...1 of its height),
    /// which selects the corresponding log line (see `jumpFromMinimap`).
    func clickMinimap(atFraction fraction: CGFloat, in app: XCUIApplication) {
        let strip = minimap(in: app)
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "The minimap should exist.")
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fraction)).click()
    }

    // MARK: - Probe readers

    /// Reads a numeric value exposed by the in-app `UITestProbe` (present only under
    /// `-uitesting`). Returns `nil` if the probe element is not yet present. The value
    /// is published via both the accessibility value and label, so try both.
    func probeInt(_ identifier: String, in app: XCUIApplication) -> Int? {
        let el = app.staticTexts[identifier]
        guard el.exists else { return nil }
        if let str = el.value as? String, let intValue = Int(str) { return intValue }
        return Int(el.label)
    }

    /// Blocks until the probe value read for `identifier` satisfies `predicate`, or
    /// the timeout elapses. Returns the last value read (which may still fail the
    /// predicate on timeout, letting the caller assert with a helpful message).
    @discardableResult
    func waitForProbe(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        until predicate: (Int) -> Bool
    ) -> Int {
        var last = probeInt(identifier, in: app) ?? -1
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            last = probeInt(identifier, in: app) ?? last
            if predicate(last) { return last }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return last
    }

    // MARK: - Small utilities

    /// Whether a checkbox/toggle element is in the on state. SwiftUI `.button`-style
    /// toggles surface as a `CheckBox` whose `value` is 0/1 rather than via
    /// `isSelected`, so read the value directly.
    func isOn(_ element: XCUIElement) -> Bool {
        if let intValue = element.value as? Int { return intValue != 0 }
        if let strValue = element.value as? String {
            return strValue == "1" || strValue.lowercased() == "true"
        }
        return element.isSelected
    }
}
