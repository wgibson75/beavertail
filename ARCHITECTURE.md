# BeaverTail Architecture

BeaverTail follows a **clean MVVM (Model–View–ViewModel) architecture** with a
dedicated **Services** layer. This document describes the layers, the rules that
keep them separated, and how to continue the migration.

## Layers

```
┌─────────────────────────────────────────────────────────────┐
│  App            BeaverTailApp, AppDelegate                    │  Scene & lifecycle wiring only
├─────────────────────────────────────────────────────────────┤
│  Views          ContentView, HelpView, HighlightSettingsView,│  SwiftUI / AppKit presentation.
│                 LogMinimapView, LogRowView, NativeLogViewer   │  Observe the view model, send intents.
├─────────────────────────────────────────────────────────────┤
│  ViewModels     LogViewModel (+ extensions),                  │  Presentation state + orchestration.
│                 HighlightRulesStore                           │  No file I/O, networking, or CoreGraphics.
├─────────────────────────────────────────────────────────────┤
│  Services       FileExportService, SessionStore,             │  Reusable, UI-free, testable units of
│                 UpdateService, CLIInstaller,                  │  work: I/O, networking, rendering,
│                 TimelineImageRenderer, IndexScanScheduler     │  serialisation, scheduling.
├─────────────────────────────────────────────────────────────┤
│  Models         LogLine, LogTab, LogContent, HighlightRule,  │  Plain data + domain logic.
│                 HelpContent, RecentFile                       │
└─────────────────────────────────────────────────────────────┘
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
| `IndexScanScheduler` | Coordinates CPU-heavy index scans across tabs. | (already a service) |

`UpdateChecker` remains as the *presentation coordinator* (it owns the
`NSAlert`s and decides when to check), delegating all networking/version math to
`UpdateService` — a clean split between "decide & present" and "do the work".

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
