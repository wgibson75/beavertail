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
| `MinimapImageRenderer` | Pure Core Graphics rendering of the minimap highlight strip. | `LogViewModel.generateMinimapData` |
| `LogComparisonService` | Pure log-line signature + good/bad "unique lines" comparison. | `LogViewModel+Compare` |
| `LiveTailService` | File-monitoring state machine (poll → deleted / rotated / appended events) + line decoding for Follow. | `LogViewModel+LiveTailing` |
| `FileLoadService` | Memory-maps a log and builds its line index incrementally, publishing throttled partial snapshots. | `LogViewModel.loadNewTab` / `triggerLazyLoadForTab` |
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
| `LiveTailService` | Line decoding (`.newlines`-set splitting, partial-line remainder carry-over, no-newline buffering); the monitor's poll state machine — unchanged/appended/rotated-or-truncated/deleted transitions against real temp files. |
| `FileLoadService` | The publish-throttle decision (first snapshot always fires, then coalesced by elapsed time); incremental map + index end-to-end against real temp files (fully-indexed result, at-least-one partial, empty file, missing-file throw). |
| `LineMatcher` / `LogContent` | Pattern classification, required-literal extraction; memory-mapped indexing (CRLF, trailing newline, empty file); parallel `filterMatches` / `extractAllMatches`. |
| `TimelineImageRenderer` | Bucketing, highest-priority line claiming, filtered vs. unfiltered columns, marks column, determinism, cancellation. |
| `MinimapImageRenderer` | The pure `minimapFills` bucketing core: MANY-lines density bands with highest-priority colouring and alpha scaling; FEW-lines full-band draw order (low-priority first); visible-range restriction; empty-range handling; cancellation. |
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

The suite is **`TailingTests`**, which exercises live-tailing (Follow): it opens
a log that is actively appended to and asserts that the **minimap** and the
**Timeline View** keep summarising it correctly. These two cases
(`testMinimapTailing`, `testTimelineViewTailing`,
`testMinimapRegionSelectionWhileTailing`) are intentionally a foundation
to be extended; the harness they establish (live feed, injected filters, probe)
is the reusable part.

Several mechanisms keep these runs fast, deterministic, and non-destructive:

- **A `-uitesting` launch argument** puts the app into a hermetic mode
  (`LogViewModel.isUITesting`): the previous session is not restored, the
  automatic GitHub update check is suppressed, and **no persisted application
  state is written back to `UserDefaults`** — session bookmarks, recent files,
  highlight rules/groups, the **Filter history** (the previous-filter list shown
  under the Filter box), and the filter display-mode preference are all guarded
  behind `isUITesting`, so tests neither depend on nor pollute the developer's
  real saved state. The Filter history additionally starts EMPTY under
  `-uitesting` (its load is skipped too), so tests never read it either.
- **Pinned view preferences via the UserDefaults *argument domain*.** Several
  view toggles (Timeline, Minimap, line numbers, font size, …) are `@AppStorage`
  values, which read the developer's real `UserDefaults` — `-uitesting` alone
  does not reset them, so they would leak into tests (e.g. the Timeline pane
  showing instead of the filter pane). `launchApp` passes `-key value` pairs
  (e.g. `-saved_show_timeline NO`) that populate the argument domain: they apply
  to that launch only, are never persisted, and so leave real settings untouched.
  (Values must not be empty strings — the app treats bare, non-`-` arguments as
  file paths to open, and `""` resolves to an existing directory.)
- **Self-contained highlight filters.** The tests must not depend on whatever
  filters the developer has configured. `launchApp` injects a known filter set by
  passing `-saved_highlight_rules <json>` (built by `HighlightFilterSpec`, whose
  keys mirror `HighlightRule`'s `Codable` shape) through the same argument domain,
  so the app decodes them into real, active rules for that launch only.
- **A live log feed (`LogFeeder`).** A self-contained Swift port of
  `scripts/writelog.py`: it streams the same word-pool lines, in the same format,
  with the same 1-second-window rate limiting, up to the target **250 KB/s** — so
  the tests do not shell out to Python. It also injects "marker" lines guaranteed
  to contain a given token, letting a test make a specific highlight filter start
  matching at a controlled moment (so the Timeline's heading count grows
  deterministically). All writes share one lock, so the volume stream and marker
  injections safely interleave on the same file handle.
- **An accessibility probe (`UITestProbe`).** The minimap and Timeline are drawn
  as bitmaps with no accessible content, so a black-box test cannot otherwise
  inspect them. Rendered **only** under `-uitesting`, this probe surfaces a few
  internal signals as readable accessibility text — total line count, whether the
  minimap/Timeline bitmaps have rendered, the highlight-match total, and the
  Timeline heading count — which the tests poll to assert that tailing keeps the
  summaries up to date. It contributes nothing to the shipping UI.
- **Opening files by path argument.** `AppDelegate` opens any file paths passed
  on the command line, so a test can open a temporary log deterministically
  without driving the system `NSOpenPanel`. Shared helpers in
  `UITestSupport.swift` create/clean up temp logs, launch and activate the app,
  enable Follow, apply filters, and poll the probe for value changes.

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
controls (the Follow toggle; the view-toggle and font-stepper toolbar items; the
tab items; the filter field; the Timeline headings; plus the `probe.*`
identifiers exposed by `UITestProbe`). A few macOS/SwiftUI realities shape how
elements are matched:

- A titled `Button`, or a control whose parent view carries its own
  `accessibilityIdentifier`, may not surface that identifier — so those are
  matched by **title/label** instead (the dependable handle for an `AXButton`).
- `.toggleStyle(.button)` toolbar toggles surface as a `CheckBox` whose on/off
  state is read from `value` (`0`/`1`), not `isSelected`.
- `Label`/summary text is often exposed via `value` rather than `label`, so
  those assertions read `value` (or are rephrased to observe a state change).
- Bitmap-only views (minimap, Timeline) have no accessible content, so the tests
  read their state from `UITestProbe` rather than inspecting pixels.

Coverage:

| Suite | What is covered |
| --- | --- |
| `TailingTests` | Live-tailing (Follow). `testMinimapTailing`: with the minimap on, the minimap renders and keeps summarising the log as it grows, and reflects highlighted entries as matching lines are appended. `testTimelineViewTailing`: with the Timeline on and a filter applied, the Timeline renders and its heading count grows deterministically as newly-tailed lines start matching additional (self-contained) highlight filters. |

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

1. **`FilteringEngine`** — move regex compilation/matching (`LineMatcher`) out of
   the `LogContent` model into a dedicated matching service.
2. **Model cleanup** — move transient presentation state (`minimapImage`,
   `timelineImage`, `selectedFraction`, `isGeneratingTimeline`) off `LogTab`, and
   split `HighlightRule`'s cached `NSColor`/`NSRegularExpression` from its Codable
   data.
3. **Replace UI Notifications** (e.g. `topPaneScrollToBottomNotification`) posted
   from the view model with observable state the views derive behaviour from.
4. **Inject `RecentFilesTracker`** instead of using the global singleton.

Already completed on this path:

- The **`LiveTailService`** extraction — the file-monitoring state machine
  previously inlined in `LogViewModel+LiveTailing`, which used
  `FileHandle`/`FileManager` directly.
- The **`MinimapImageRenderer`** extraction — the pure Core Graphics minimap
  rendering previously inlined in `LogViewModel.generateMinimapData` (now
  orchestrated from `LogViewModel+Minimap`), mirroring `TimelineImageRenderer`.
- The **`FileLoadService`** extraction — the memory-map + incremental index build
  (with publish throttling) previously inlined in `LogViewModel.loadNewTab` and
  `triggerLazyLoadForTab`; both call sites now share it and only orchestrate tab
  state.

Each step is independent and can land incrementally while keeping the app
building — verify with:

```sh
xcodebuild -project BeaverTail.xcodeproj -scheme BeaverTail -configuration Debug build CODE_SIGNING_ALLOWED=NO
```
