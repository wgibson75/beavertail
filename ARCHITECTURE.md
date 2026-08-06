# BeaverTail Architecture

BeaverTail follows a **clean MVVM (Model–View–ViewModel) architecture** with a
dedicated **Services** layer. This document describes the layers, the rules that
keep them separated, and how to continue the migration.

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│  App            BeaverTailApp, AppDelegate                   │  Scene & lifecycle wiring only
├──────────────────────────────────────────────────────────────┤
│  Views          ContentView, HelpView, HighlightSettingsView,│  SwiftUI / AppKit presentation.
│                 LogMinimapView, LogRowView, NativeLogViewer  │  Observe the view model, send intents.
├──────────────────────────────────────────────────────────────┤
│  ViewModels     LogViewModel (+ extensions),                 │  Presentation state + orchestration.
│                 HighlightRulesStore                          │  No file I/O, networking, or CoreGraphics.
├──────────────────────────────────────────────────────────────┤
│  Services       FileExportService, SessionStore,             │  Reusable, UI-free, testable units of
│                 UpdateService, CLIInstaller,                 │  work: I/O, networking, rendering,
│                 TimelineImageRenderer, IndexScanScheduler    │  serialisation, scheduling.
├──────────────────────────────────────────────────────────────┤
│  Models         LogLine, LogTab, LogContent, HighlightRule,  │  Plain data + domain logic.
│                 HelpContent, RecentFile                      │
└──────────────────────────────────────────────────────────────┘
```

## Separation rules

- **Views** never perform business logic, file I/O, or networking. They render
  the view model's published state and call view-model methods in response to
  user actions.
- **ViewModels** hold presentation state (`@Published`) and *orchestrate*. They
  decide *what* should happen and delegate *how* it happens to Services. A view
  model must not contain `URLSession`, `FileHandle`, `CGContext`, `Process`, or
  UserDefaults serialisation code inline.
- **Services** are UI-free and, wherever they run off the main actor, marked
  `nonisolated`. They take plain value inputs and return plain results, so they
  can be unit-tested without a running app.
- **Models** are data-first. Domain logic that operates purely on model data may
  live here; presentation concerns must not.

## The Services layer

Introduced to lift "core logic" out of the previously monolithic `LogViewModel`:

| Service | Responsibility | Extracted from |
| --- | --- | --- |
| `FileExportService` | Streams filtered lines to disk in bounded-memory batches. | `LogViewModel+Export` |
| `SessionStore` | JSON + security-scoped bookmark encode/decode for the open-tabs session. | `LogViewModel+Persistence` |
| `UpdateService` | GitHub "latest release" networking and version comparison. | `UpdateChecker` |
| `CLIInstaller` (`BTailInstaller`) | Installs the `btail` shell helper (filesystem + shell). | `BeaverTailApp` |
| `TimelineImageRenderer` | Pure Core Graphics rendering of the per-rule density timeline. | `LogViewModel+Timeline` |
| `LogComparisonService` | Pure log-line signature + good/bad "unique lines" comparison. | `LogViewModel+Compare` |
| `IndexScanScheduler` | Coordinates CPU-heavy index scans across tabs. | (already a service) |

`UpdateChecker` remains as the *presentation coordinator* (it owns the
`NSAlert`s and decides when to check), delegating all networking/version math to
`UpdateService` — a clean split between "decide & present" and "do the work".

## Testing

Unit tests live in the **`BeaverTailTests`** target (a hosted
`com.apple.product-type.bundle.unit-test` bundle) and use `@testable import
BeaverTail`. They are kept **separate from the UI tests** (see below) — this
target contains no `XCUIApplication`/`XCUIElement` usage; it exercises logic
directly and asserts on return values and state without rendering any view.

The clean layering above is what makes this possible: because the Services,
plus the pure logic on the Models and ViewModel, take plain value inputs and
return plain results, they can be tested without a running UI.

Coverage by layer:

| Layer / unit | What is covered |
| --- | --- |
| `LogComparisonService` | Line-signature normalisation; union/intersection "unique lines" set logic; cancellation; parallel-scan correctness. |
| `LineMatcher` / `LogContent` | Pattern classification, required-literal extraction; memory-mapped indexing (CRLF, trailing newline, empty file); parallel `filterMatches` / `extractAllMatches`. |
| `TimelineImageRenderer` | Bucketing, highest-priority line claiming, filtered vs. unfiltered columns, marks column, determinism, cancellation. |
| `SessionStore` | Session JSON round-trip; bookmark encode/resolve incl. malformed and deleted-file failure modes. |
| `FileExportService` | Filename suggestion; buffered writing incl. the >1 MB flush path. |
| `UpdateService` | Version normalisation (`v`-strip) and component-wise comparison. |
| `IndexScanScheduler` | Mutual exclusion, prioritisation, cancellation, single-holder invariant under concurrency. |
| `HighlightRule` / `HighlightFiltersDocument` | Codable round-trips, legacy-data defaults, regex compilation, group-vs-rule disambiguation. |
| `LogTab` / providers | Visible-bounds maths, `FilteredLineProvider` / `RangeLineProvider` indexing, Codable & equality. |
| `LogViewModel` (+ extensions) | Coordinate mapping & match jumps (Navigation); line-visibility / time-period history; filter-history & recent-files dedup/truncation; tab marking and the end-to-end "Find Unique Lines" pipeline. |

ViewModel tests that touch the `@MainActor LogViewModel` snapshot and restore the
persistence `UserDefaults` keys (and the `RecentFilesTracker` singleton) so they
run in isolation and leave the developer's real saved state untouched.

Run them with:

```sh
xcodebuild test -project BeaverTail.xcodeproj -scheme BeaverTail \
  -destination 'platform=macOS' -only-testing:BeaverTailTests
```

UI-level behaviour is covered separately (see below). External-dependency
integration (the `UpdateService.fetchLatestRelease` network path via a
`URLProtocol` stub, `openRecentFile`) remains **out of scope** for both targets
and belongs in a future integration target.

### UI tests

UI tests live in the **`BeaverTailUITests`** target (a
`com.apple.product-type.bundle.ui-testing` bundle). These are **black-box**
tests: they launch the real, built app and drive it through the accessibility
hierarchy via `XCUIApplication` — there is no `@testable import`, so they see
only what a user would.

Three mechanisms keep these runs fast, deterministic, and non-destructive:

- **A `-uitesting` launch argument** puts the app into a hermetic mode
  (`LogViewModel.isUITesting`): the previous session is not restored, no
  session/recent-files state is written back to `UserDefaults`, and the
  automatic GitHub update check is suppressed — so tests neither depend on nor
  pollute the developer's real saved state, and no networked alert interferes.
- **Pinned view preferences via the UserDefaults *argument domain*.** Several
  view toggles (Timeline, Minimap, line numbers, font size, …) are `@AppStorage`
  values, which read the developer's real `UserDefaults` — `-uitesting` alone
  does not reset them, so they would leak into tests (e.g. the Timeline pane
  showing instead of the filter pane). `launchApp` passes `-key value` pairs
  (e.g. `-saved_show_timeline NO`) that populate the argument domain: they apply
  to that launch only, are never persisted, and so leave real settings untouched.
  (Values must not be empty strings — the app treats bare, non-`-` arguments as
  file paths to open, and `""` resolves to an existing directory.)
- **Opening files by path argument.** `AppDelegate` opens any file paths passed
  on the command line, so a test can open a temporary log deterministically
  without driving the system `NSOpenPanel`. Shared helpers in
  `UITestSupport.swift` create/clean up temp logs, launch and activate the app,
  apply filters, open tab context menus, and poll for value changes.

**macOS 26.x window-presentation workaround.** Under XCUITest on macOS 26.x, the
SwiftUI `WindowGroup` can launch with **zero windows** — the app is foreground
and the menu bar is present, but no window is ever created, so every UI test
times out. To stay robust, the app (only under `-uitesting`) installs a pure
**AppKit fallback window** from `AppDelegate`: shortly after launch, if no
content window exists, it creates an `NSWindow` hosting the same `ContentView`,
bound to the one shared `LogViewModel`. On macOS versions where the `WindowGroup`
does present, the fallback detects the existing window and is skipped (no
duplicate). Because the fallback appears a moment after launch — and the
`WindowGroup`'s `ContentView` body may never run on 26.x — file-open requests are
handled **centrally in `AppDelegate`** (an observer of `openFileURLNotification`
loading into the shared view model) rather than via a `ContentView.onReceive`.
This makes file loading independent of whether/when any window is instantiated,
so files passed at launch load reliably regardless of the window path taken.

**Thread Performance Checker disabled for the test action.** The scheme's Test
action sets `disablePerformanceAntipatternChecker = "YES"`. XCUITest's automation
transport synchronously blocks the runner's user-interactive main thread on an
XPC round-trip (during `typeText`/`waitForExistence`, etc.) that is serviced at
the Default QoS, which the Thread Performance Checker reports as an `[Internal]`
priority-inversion "…waiting on a lower QoS thread running at Default…" against
the driving test method. These originate in the framework, not in app or test
code (an app-side QoS change to the filter scan had no effect on them), so the
checker is turned off for the test run to remove the false positives. The more
important **Main Thread Checker remains enabled**, so genuine
UI-updates-off-the-main-thread bugs are still caught.

Stable selectors come from **accessibility identifiers** on the high-value
controls (the Highlight Filters toggle; the view-toggle and font-stepper toolbar
items; the tab items and their Close buttons; the filter field; the font-size
label; the Reset-hidden-lines button). A few macOS/SwiftUI realities shape how
elements are matched:

- A titled `Button`, or a control whose parent view carries its own
  `accessibilityIdentifier`, may not surface that identifier — so those are
  matched by **title/label** instead (the dependable handle for an `AXButton`).
- `.toggleStyle(.button)` toolbar toggles surface as a `CheckBox` whose on/off
  state is read from `value` (`0`/`1`), not `isSelected`.
- `Label`/summary text is often exposed via `value` rather than `label`, so
  those assertions read `value` (or are rephrased to observe a state change).

Coverage:

| Suite | What is covered |
| --- | --- |
| `SmokeUITests` | Clean-launch empty state renders; opening a file replaces the empty state with tab/content. |
| `MenuUITests` | Presence of core File/App/Help menu commands; "Save to File…" is disabled until a unique-lines results tab is active. |
| `HighlightFiltersWindowUITests` | The toolbar toggle opens and closes the standalone Highlight Filters window. |
| `CompareUITests` | The mark → compare → results flow: marking reveals Clear items; comparison commands are gated on having a Good and a Bad; end-to-end unique-lines creates a results tab and enables "Save to File…". |
| `FilteringUITests` | The bottom-pane regex filter: matching shows results, non-matching shows "No lines matched", an invalid regex is handled gracefully, and clearing restores the prompt. |
| `ToolbarUITests` | View toggles (Minimap/Timeline/line numbers) flip on/off; the font stepper updates its label and clamps at the 8–24pt bounds. |
| `LineHidingUITests` | Hiding lines from the top-pane menu surfaces the Reset affordance and changes the summary; Reset restores the full view. |
| `TabManagementUITests` | Multiple files create tabs; ⌘W closes the active tab (not the window); closing the last tab returns to the empty state. |
| `TimelineOverlayUITests` | The Timeline "Processing highlight filters…" overlay is never left stuck after a filter change (transient appearance is best-effort). |
| `HelpUITests` | The Help sheet opens from the menu and its search box filters topics. |

Deliberately **kept out** of the UI target as too brittle or not observable
via the accessibility API: pixel/appearance assertions (toggle-indicator
visibility, group dimming, glow, exact button geometry), real
`NSOpenPanel`/`NSSavePanel` dialogs, and gesture-heavy minimap drag/scroll
sync — these remain manual/visual checks.

Run them with:

```sh
xcodebuild test -project BeaverTail.xcodeproj -scheme BeaverTail \
  -destination 'platform=macOS' -only-testing:BeaverTailUITests
```

## Roadmap — continuing the migration

The same extract-into-a-service pattern should be applied next to the remaining
in-view-model core logic, in rough priority order:

1. **`LiveTailService`** — file-monitoring state machine currently in
   `LogViewModel+LiveTailing` (uses `FileHandle`/`FileManager` directly).
2. **`MinimapImageRenderer`** — pure Core Graphics rendering in
   `LogViewModel.generateMinimapData` (mirror of `TimelineImageRenderer`).
3. **`FileLoadService`** — memory-map + incremental index build in
   `LogViewModel.loadNewTab` / `triggerLazyLoadForTab`.
4. **`FilteringEngine`** — move regex compilation/matching (`LineMatcher`) out of
   the `LogContent` model into a dedicated matching service.
5. **Model cleanup** — move transient presentation state (`minimapImage`,
   `timelineImage`, `selectedFraction`, `isGeneratingTimeline`) off `LogTab`, and
   split `HighlightRule`'s cached `NSColor`/`NSRegularExpression` from its Codable
   data.
6. **Replace UI Notifications** (e.g. `topPaneScrollToBottomNotification`) posted
   from the view model with observable state the views derive behaviour from.
7. **Inject `RecentFilesTracker`** instead of using the global singleton.

Each step is independent and can land incrementally while keeping the app
building — verify with:

```sh
xcodebuild -project BeaverTail.xcodeproj -scheme BeaverTail -configuration Debug build CODE_SIGNING_ALLOWED=NO
```
