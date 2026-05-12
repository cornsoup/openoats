# Unified OpenOats Window

**Date:** 2026-05-04
**Status:** Draft
**Branch:** `jja/custom`
**Builds on:** the stacked-panes architecture (`2026-04-11-stacked-panes-redesign-design.md`) and the unified live-summary panel (`2026-04-20-live-summary-detail-slider-and-sections-design.md`).

## Problem

OpenOats currently shows three top-level windows: the recording window (`main`), the past-meetings window (`notes`), and the optional Transcript window. The recording and past-meetings windows have overlapping concerns — both are about meetings — but they live separately. Switching between them is friction. Past meetings can't be referenced while recording without window juggling.

We want a single primary window where past meetings live alongside the live recording surface. The user can pop a past meeting into its own window only when they explicitly want to (e.g. to refer to it during a recording).

## Design Goals

1. **One primary window** for the app: sidebar of past meetings, right pane that shows either the live session or the selected past meeting, persistent control bar at the bottom.
2. **Past meetings on demand in their own windows** — opt-in pop-out, opens automatically only when the right pane is busy with a recording.
3. **No data migration.** All meeting data lives in `SessionRepository`; this is purely a UI restructure.
4. **No engine-layer changes.** `LiveSessionController`, `NotesEngine`, `LiveSummaryEngine`, `SuggestionEngine`, etc. are untouched beyond the call-site wiring needed for the new view ownership.
5. **Transcript window unchanged.** Users like that as a separate floatable window.

## Window Topology

| Window | Role | Lifecycle |
|--------|------|-----------|
| **OpenOats** (`Window` scene, `id: "openoats"`) | Primary unified window. Sidebar + recording-or-detail + control bar. | Single instance. Replaces today's `main` + `notes` windows. |
| **Past Meeting** (`WindowGroup`, `id: "meeting"`, `for: String.self`) | Read/edit one past session in its own window. | One window per session ID, opened on demand. Re-opening with the same ID focuses the existing window. |
| **Transcript** (`Window` scene, `id: "transcript"`) | Live transcript in a separate window. | Unchanged from today. |
| **Settings** | Standard SwiftUI Settings scene. | Unchanged. |

The old `main` window scene is removed. Its content (the `StackedPanesView` and the bottom `ControlBar`) moves into the unified window.

## Unified Window Layout

```
┌────────────────────────────────────────────────────────────┐
│  ◀▶  OpenOats                                              │
├──────────────┬─────────────────────────────────────────────┤
│              │                                             │
│   Sidebar    │         Detail area (state machine)         │
│  (past       │                                             │
│   meetings)  │   ┌─────────────────────────────────────┐  │
│              │   │ Recording? → StackedPanesView +     │  │
│   ~250pt     │   │              scratchpad             │  │
│              │   │                                     │  │
│              │   │ Idle + sel? → past meeting detail   │  │
│              │   │                                     │  │
│              │   │ Idle + no sel? → empty/start state  │  │
│              │   └─────────────────────────────────────┘  │
│              │                                             │
├──────────────┴─────────────────────────────────────────────┤
│  ●  Live  00:42   [mute]  [▮▮▮▮]              model · v… │
└────────────────────────────────────────────────────────────┘
```

### Sidebar (left, ~250pt)

Identical to today's `NotesView.sidebar`. Past meetings grouped by recency, search, folder hierarchy, context-menu actions for rename/folder/delete. No changes to the sidebar contents themselves; only its hosting context changes.

### Detail Area (right, fills remainder)

A state machine with three states, driven by `controllerState.isRunning` and `notesController.state.selectedSessionID`:

| State | Render |
|-------|--------|
| `isRunning == true` | `StackedPanesView(controllerState:settings:focusedPane:)` plus the collapsible `ScratchpadSection`. Same layout/code as today's main window's detail area. |
| Idle, session selected | The current `NotesView.detailContent(controller:state:)` — meeting title, notes/transcript/scratchpad/attachments tabs, regenerate buttons, etc. |
| Idle, no session | Simple empty state: "Start a new meeting from below, or pick a past one from the sidebar." Optionally a small upcoming-calendar-meetings preview if `settings.calendarIntegrationEnabled` is true. |

### Control Bar (bottom, full window width)

The current `ControlBar` (Start / Live / Mute / audio-level / model display / build info) extracted from `ContentView` and pinned to the bottom of the unified window's root `VStack`. Spans both the sidebar and the detail area horizontally. Always visible regardless of state — so the user can start a recording from any sidebar selection or empty state.

### State Transitions

- **Start recording while viewing a past meeting:** detail area swaps from past-meeting view to recording UI. Sidebar selection clears (highlighted row goes away).
- **Stop recording:** sidebar auto-selects the just-ended session. Detail swaps to its notes view, which renders the "Generating notes…" spinner if `NotesEngine` is mid-flight.
- **Click a past meeting in the sidebar while recording:** opens that session in a new Past Meeting window automatically (single-click). The unified window's detail area stays on the recording.
- **Click a past meeting in the sidebar while idle:** loads in the right pane (current Notes behavior).
- **⌘-click a past meeting:** always opens in a new Past Meeting window, regardless of state. (Mac convention for "open in new place".)
- **Right-click a past meeting → "Open in New Window":** always opens in a new Past Meeting window, regardless of state.

## Past Meeting Window

```swift
WindowGroup("Past Meeting", id: "meeting", for: String.self) { sessionID in
    PastMeetingWindowView(sessionID: sessionID)
        .environment(container)
        .environment(coordinator)
}
.defaultSize(width: 720, height: 700)
```

A `WindowGroup` parameterized by `String` (session ID) gives:
- One window per session, opened with `openWindow(id: "meeting", value: sessionID)`.
- Re-opening with the same ID focuses the existing window (built-in macOS behavior).
- Multiple sessions can have their own windows simultaneously.
- macOS "Window" menu lists all open meeting windows with their titles automatically.

### `PastMeetingWindowView` Content

Same content as the unified window's detail pane in idle+selected state — meeting title header, notes/transcript/scratchpad/attachments tabs (whatever `NotesView.detailContent` already renders). No sidebar, no control bar.

### Window Title

The meeting's title (e.g. "Payment Ops sync — Apr 22"). Falls back to "Untitled meeting" if title is empty.

### Edit / Regenerate Behavior

Identical to the current notes detail pane. "Regenerate Notes" still works from the pop-out; the work is done by the same shared `NotesEngine` on the coordinator. Notes updates flow through to both the pop-out and the unified window's sidebar (the sidebar's "freshly generated" badge still applies).

### Pop-out Triggers

| Trigger | Source | Behavior |
|---------|--------|----------|
| Right-click → "Open in New Window" | sidebar row context menu | Always available |
| Single-click during recording | sidebar | Auto-opens new window |
| ⌘-click on sidebar row | sidebar | Always opens new window |
| Deep link `openoats://notes/<id>` | external | Focuses unified window, selects in sidebar — UNLESS unified window is recording, in which case opens the pop-out |
| Menu: Open Selected in New Window (⇧⌘O) | menu | Pops the unified window's currently selected session into a new window |

### Coexistence Rules

- The same session can be open in BOTH the unified window's detail and a pop-out simultaneously. They both observe the same underlying `SessionRepository` data and stay in sync.
- Closing the unified window doesn't close pop-outs (and vice versa).
- A session being actively recorded cannot be opened in a pop-out (the pop-out is for past meetings only). Attempts to do so are no-ops.

## Controller Architecture

- **`NotesController`** stays as today — owned by the unified window's right pane. When the right pane is in "idle + session selected" state, this controller drives it. `NotesController` is unchanged.
- **`PastMeetingViewModel`** (new, session-scoped) — owned by `PastMeetingWindowView`. Loads one session's records/notes/scratchpad from `SessionRepository`. Triggers `NotesEngine.generate(...)` on regenerate. Observes `SessionRepository` for cross-window updates.
- **Cross-window sync:** Pop-out and unified window viewing the same session: both observe `SessionRepository`'s notifications, so notes regenerated from one window appear live in the other.

`PastMeetingViewModel` is intentionally lighter than `NotesController` — it doesn't manage a session list, doesn't handle folders, doesn't navigate. It just holds a single session's loaded data and exposes regenerate/save actions.

## Menu Commands

| Command | Shortcut | Behavior |
|---------|----------|----------|
| Toggle Meeting | ⇧⌘L | Starts/stops recording in unified window. Unchanged. |
| Past Meetings | ⇧⌘M | Brings unified window forward, focuses sidebar. (Was: opens Notes window.) |
| Import Meeting Recording… | ⇧⌘I | Unchanged. |
| Zoom In/Out/Reset | ⌘=, ⌘-, ⌘0 | Unchanged. |
| **Open Selected in New Window** | ⇧⌘O | **New.** Pops the sidebar's currently-selected session into a Past Meeting window. Disabled when no session is selected. |
| GitHub Repository… | — | Unchanged. |
| Check for Updates… | — | Unchanged. |

The macOS "Window" menu auto-populates with the unified window plus any open Past Meeting and Transcript windows.

## Deep Links

| URL | Behavior |
|-----|----------|
| `openoats://notes/<id>` | Focus unified window. If not recording, select session in sidebar. If recording, auto-open Past Meeting pop-out for that ID. |
| `openoats://record/start`, `openoats://record/stop` | Operate on the unified window's recording state. Unchanged in spirit. |
| Other commands | Unchanged. |

## Menu Bar App (`LSUIElement` mode)

- "Show OpenOats" entry opens/focuses the unified window.
- "Past Meetings" entry is removed (or aliased to "Show OpenOats" — same result now).
- All other menu bar popover entries unchanged.

## App Activation

- Clicking the dock icon brings the unified OpenOats window forward.
- If only Past Meeting pop-outs are open and the unified window is closed, dock-icon click reopens the unified window.

## Edge Cases

**Closing the unified window during recording.** Recording continues in the background. Menu bar icon shows live state (when `LSUIElement` is enabled). Re-opening the unified window or clicking the menu bar icon brings the live recording UI back.

**Closing a Past Meeting pop-out.** Independent — doesn't affect the unified window, doesn't stop any in-flight notes regeneration on that session (that work is owned by the shared `NotesEngine`).

**Sidebar focus during recording:** Sidebar selection clears when recording starts (no row highlighted). When recording stops, the sidebar selection sets to the just-ended session ID; the detail swaps to that session's notes view.

**Scene state / migration:** The old `main` and `notes` window IDs disappear. SwiftUI scene restoration will discard saved window frames for those IDs. Users get default-sized unified windows on first launch post-update — minor cosmetic regression, no data loss.

**Settings:** No `AppSettings` changes required. `summaryDetailLevel`, collapse flags, etc. are unchanged.

## Files to Modify / Create

| File | Change |
|------|--------|
| `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift` | Replace `Window("OpenOats", id: "main") { ContentView(...) }` and `Window("Notes", id: "notes") { NotesView(...) }` with a single `Window("OpenOats", id: "openoats") { UnifiedOpenOatsView(...) }`. Add new `WindowGroup("Past Meeting", id: "meeting", for: String.self) { ... }`. Update menu commands ("Past Meetings" target, add "Open Selected in New Window"). |
| **New:** `OpenOats/Sources/OpenOats/Views/UnifiedOpenOatsView.swift` | Top-level view for the unified window. Hosts sidebar (today's `NotesView.sidebar`), the detail-area state machine, and the persistent `ControlBar` at the bottom. |
| `OpenOats/Sources/OpenOats/Views/NotesView.swift` | Refactor: extract `sidebar(...)` and `detailContent(...)` into reusable view methods/types so `UnifiedOpenOatsView` can host them. The `NotesView` type itself is removed (its responsibilities split between the unified window and the pop-out window). |
| `OpenOats/Sources/OpenOats/Views/ContentView.swift` | Removed entirely (or stripped to nothing). Its concerns move into `UnifiedOpenOatsView`. |
| **New:** `OpenOats/Sources/OpenOats/Views/PastMeetingWindowView.swift` | Pop-out window root view. Hosts `PastMeetingViewModel` and renders the same notes/transcript detail content as the unified window's detail pane. |
| **New:** `OpenOats/Sources/OpenOats/App/PastMeetingViewModel.swift` | Session-scoped view model. Loads one session's records/notes/scratchpad. Triggers `NotesEngine.generate(...)` on regenerate. Observes `SessionRepository`. |
| `OpenOats/Sources/OpenOats/App/OpenOatsDeepLink.swift` | Update `openNotes(sessionID)` handler: focus unified window if not recording, otherwise open pop-out window. |
| `OpenOats/Sources/OpenOats/App/MenuBarController.swift` | "Show OpenOats" target updated to unified window ID. Remove or alias "Past Meetings" entry. |

## Files NOT Modified

- `Intelligence/*` — engines untouched.
- `Audio/*` — capture pipeline untouched.
- `Transcription/*` — transcription pipeline untouched.
- `Storage/SessionRepository.swift` — repository untouched.
- `Settings/SettingsStore.swift` — no settings added or removed.
- `Views/StackedPanesView.swift`, `Views/LiveSummaryPanel.swift`, `Views/TranscriptView.swift`, `Views/ControlBar.swift` — reused as-is.
- `Views/TranscriptWindowView.swift` — Transcript window unchanged.
- `App/LiveSessionController.swift` — unchanged. The unified window simply observes `coordinator.liveSessionController.state` like the old main window did.

## Testing

**Unit tests:** `NotesController` and `LiveSessionController` test suites carry forward unchanged. `PastMeetingViewModel` gets unit tests covering: load-session-from-repo, regenerate-notes-via-engine, observe-repository-updates.

**UI smoke tests:** existing `app.controlBar.*` and pane accessibility identifiers stay valid. Tests that previously opened the Notes window are retargeted at the unified window's sidebar interactions. A new smoke test exercises pop-out open/close and the recording-active sidebar-click flow.

**Manual validation pass:**
- Recording starts/stops cleanly from the unified window in all three idle states (no selection, with selection, after a previous recording).
- Sidebar click on a past meeting:
  - While idle: loads in detail pane.
  - While recording: opens new Past Meeting window.
  - With ⌘-click or right-click → "Open in New Window": always pops out.
- Multiple Past Meeting windows can be open simultaneously; each shows its own session.
- Editing/regenerating notes in a pop-out updates the unified window's sidebar badge.
- Deep link `openoats://notes/<id>` while recording correctly opens a pop-out.
- Dock-icon click reopens the unified window when closed.
- Menu bar app's "Show OpenOats" focuses the unified window.

## Risks

1. **WindowGroup re-open semantics.** `WindowGroup(for: String.self)` re-opens with the same ID and focuses the existing window — but only if SwiftUI's window state restoration is healthy. If state restoration is disabled or the user has explicitly closed the pop-out, opening "the same" session may produce a fresh window rather than focusing. Acceptable.
2. **Cross-window data sync.** `PastMeetingViewModel` and the unified window's `NotesController` observing `SessionRepository` independently could double-fire UI updates when notes are regenerated. Should be visually fine (both windows just re-render the same content) but worth eyes-on during manual QA.
3. **Sidebar refactor blast radius.** Today's `NotesView` is a 3,000+ line file with deeply intertwined sheet/dialog/confirmation state. Extracting `sidebar(...)` and `detailContent(...)` into reusable units is the highest-risk refactor in this redesign. Plan budget assumes one task purely for this extraction.
4. **Scene state forgetting.** Users will lose their saved window frames for `main` and `notes` on first launch post-update. Cosmetic only. If this matters, we could add an `AppDelegate` hook that copies the old `main` frame to `openoats` on first launch — but YAGNI for now.
5. **Pop-out title staleness.** If a meeting is renamed in the unified sidebar while a pop-out for it is open, the pop-out's window title needs to update. SwiftUI `WindowGroup` titles can be bound to model state; verify this pattern works on macOS 26.

## Non-Goals

- No redesign of the sidebar's contents or grouping logic.
- No changes to the Transcript window.
- No changes to `NotesEngine`, `LiveSessionController`, `LiveSummaryEngine`, `SuggestionEngine`, or any engine-layer code.
- No "split view" inside the unified window where the user can show recording AND a past meeting side by side. (Users use Past Meeting pop-outs for that.)
- No multi-session selection in the sidebar. Single-select like today.
- No persistence of Past Meeting window positions across app launches (whatever SwiftUI gives us by default is fine).
- No "open all" or "close all pop-outs" affordance.
- No keyboard navigation between the unified window and pop-outs (rely on standard macOS Cmd-` and Window menu).
