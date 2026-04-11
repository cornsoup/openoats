# Stacked Panes UI Redesign

**Date:** 2026-04-11
**Status:** Draft
**Branch:** `jja/custom`

## Problem

The current UI mixes two different display strategies for live-session information:
- **Transcript** renders inline in the main window (inside an HSplitView alongside the summary panel)
- **Suggestions** render in a *floating* always-on-top panel, with a status bar in the main window showing its show/hide state
- **Summary** renders inline alongside the transcript

This produces a cluttered, inconsistent layout. The user explicitly does not want a floating suggestion panel. They want all three information streams (transcript, summary, suggestions) visible in the main window, each independently collapsible, resizable, and zoomable.

## Design Goals

1. **Three inline panes in the main window** — transcript, meeting summary, suggestions
2. **Stacked vertically** — each pane takes full window width, stacked top-to-bottom
3. **Collapsible** — each pane has a disclosure header; collapsed panes reduce to just the header row
4. **Resizable vertically** — draggable dividers between panes let the user allocate vertical space
5. **Per-pane zoom** — Cmd+/-/0 zoom the focused pane's text independently
6. **Click-to-focus** — clicking inside a pane sets it as the zoom target; focused pane shows a thin border
7. **Persistence** — zoom levels and collapsed states persist across app launches
8. **Menu bar discoverability** — zoom commands appear in a "View" menu
9. **Hide the floating panel UI** — the overlay code stays but is commented out so it can be restored later

## Layout

```
┌──────────────────────────────────────────┐
│  Header (OpenOats title, KB, Settings)   │
├──────────────────────────────────────────┤
│  ▼ Transcript           (5 utterances)   │  ← disclosure header
│  ┌────────────────────────────────────┐  │
│  │  [00:01:02] You: ...               │  │
│  │  [00:01:09] Them: ...              │  │
│  └────────────────────────────────────┘  │
│  ═══════ draggable divider ══════════════│
│  ▼ Meeting Summary                       │
│  ┌────────────────────────────────────┐  │
│  │  Discussed the launch timeline...  │  │
│  │  Key Points                        │  │
│  │  • Launch moved to 4/15            │  │
│  └────────────────────────────────────┘  │
│  ═══════ draggable divider ══════════════│
│  ▶ Suggestions                           │  ← collapsed example
├──────────────────────────────────────────┤
│  Scratchpad + Control Bar                │
└──────────────────────────────────────────┘
```

**Ordering (fixed, top to bottom):**
1. Transcript
2. Meeting Summary
3. Suggestions

**Implementation:** SwiftUI `VSplitView` wraps the three pane views. `VSplitView` provides draggable dividers between children and respects each child's `minHeight`/`idealHeight` constraints. The existing `HSplitView` block in `ContentView` is removed.

**Visibility gating:** The stacked panes only appear when the live session is running (`controllerState.isRunning == true`). When not running, the main window returns to its simpler idle layout (no transcript, no summary, no suggestions — matching current behavior).

## Pane Architecture

### PaneShell (reusable wrapper)

A new view `PaneShell` encapsulates the common behavior of each pane:

```swift
struct PaneShell<Content: View>: View {
    let title: String
    let badge: String?        // e.g., "(5)" for transcript count
    let paneID: PaneID
    @Binding var isCollapsed: Bool
    let focusedPane: FocusedPaneStore
    let content: () -> Content
}
```

**Responsibilities:**
- Renders a disclosure header row with chevron, title, and optional badge
- Clicking the header toggles `isCollapsed`
- When collapsed, only the header row is visible (~28pt tall)
- When expanded, renders `content()` below the header
- Wraps content in a click-capture overlay that sets `focusedPane.focused = paneID`
- Shows a thin accent-colored border (1pt, 50% opacity) around the pane when it is focused
- The badge is optional — only the transcript uses it for utterance count

**PaneID enum:**
```swift
enum PaneID: String, CaseIterable {
    case transcript
    case summary
    case suggestions
}
```

### FocusedPaneStore

A small `@Observable` class that holds the currently focused pane ID:

```swift
@Observable
@MainActor
final class FocusedPaneStore {
    var focused: PaneID? = nil
}
```

Lives inside `ContentView` as `@State`, passed to both `PaneShell` (so panes can read their focus status and claim focus on click) and to the menu command handlers (so Cmd+/- knows which pane to target). The same instance is also threaded into `OpenOatsApp` via `.environment(...)` so the View menu commands can read it.

### StackedPanesView

A new view that composes the three panes inside a `VSplitView`:

```swift
struct StackedPanesView: View {
    let controllerState: LiveSessionState
    @Bindable var settings: AppSettings
    @Bindable var focusedPane: FocusedPaneStore
}
```

Responsibilities:
- Renders the `VSplitView` with three `PaneShell` children
- Binds each pane's `isCollapsed` to the corresponding setting (`settings.transcriptCollapsed`, etc.)
- Passes each pane's content a `zoom:` parameter from the corresponding setting (`settings.transcriptZoom`, etc.)
- Provides the focused pane store to child shells
- Sets appropriate `minHeight` on each pane: ~28pt when collapsed (just header), ~80pt when expanded (header + minimum content)

## Pane Content Views

### TranscriptView

Existing view. Modified to accept a `zoom: Double` parameter. All `Text(...)` calls that render utterance content multiply their base font size by `zoom`. Dividers, timestamps, speaker labels, and padding stay at fixed sizes.

Example:
```swift
Text(utterance.displayText)
    .font(.system(size: 13 * zoom))
```

### LiveSummaryPanel

Existing view (accumulating summary + key points). Modified to accept a `zoom: Double` parameter. The summary body text (`Text(summary)`) and key point bullets multiply their base size by `zoom`. Section headers (`"Meeting Summary"`, `"Key Points"`) stay fixed.

### InlineSuggestionsView (new)

A new view that renders `LiveSessionState.suggestions` as an inline scrollable list. Adapted from the existing `SuggestionPanelContent` (which the floating overlay used), but simplified for inline display:
- No window chrome, no always-on-top styling
- Just a `ScrollView { VStack { ForEach(suggestions) { ... } } }`
- Each suggestion shows the text and any KB source breadcrumbs
- Accepts a `zoom: Double` parameter applied to suggestion body text
- Empty state: "Waiting for suggestions..." in tertiary color

Input: `let suggestions: [Suggestion]` and `let zoom: Double`.

## Zoom System

### Settings properties

Six new settings in `AppSettings`:

| Name | Type | Default | Description |
|---|---|---|---|
| `transcriptZoom` | Double | 1.0 | Font scale for transcript pane |
| `summaryZoom` | Double | 1.0 | Font scale for summary pane |
| `suggestionsZoom` | Double | 1.0 | Font scale for suggestions pane |
| `transcriptCollapsed` | Bool | false | Whether transcript pane is collapsed |
| `summaryCollapsed` | Bool | false | Whether summary pane is collapsed |
| `suggestionsCollapsed` | Bool | false | Whether suggestions pane is collapsed |

All persisted in `UserDefaults` via the existing `AppSettings` pattern.

**Zoom bounds:**
- Min: 0.7
- Max: 2.0
- Step: 0.1

The zoom modifier functions clamp to these bounds.

### View menu commands

A new `CommandMenu("View")` in `OpenOatsApp.swift` (inside the `.commands { ... }` modifier on the main `WindowGroup`) with three items:

| Label | Shortcut | Action |
|---|---|---|
| Zoom In | ⌘= | Increase focused pane zoom by 0.1, clamped to 2.0 |
| Zoom Out | ⌘- | Decrease focused pane zoom by 0.1, clamped to 0.7 |
| Reset Zoom | ⌘0 | Set focused pane zoom to 1.0 |

Each command reads `focusedPane.focused` and mutates the corresponding `settings.*Zoom` property. If no pane is focused, the commands are disabled (`.disabled(focusedPane.focused == nil)`).

To make the `focusedPane` store accessible from the `.commands` closure, it is created as a `@State` in `OpenOatsApp` and injected into the environment via `.environment(focusedPane)` on the WindowGroup content. `ContentView` reads the same instance via `@Environment(FocusedPaneStore.self)`.

## Collapse Behavior

- Clicking the disclosure chevron or header row toggles `isCollapsed` for that pane
- Collapsed pane: only the header row visible, height clamped to ~28pt via `.frame(height: 28)`
- Expanded pane: header row + content, `minHeight: 80`, `idealHeight: proportional to available space`
- `VSplitView` handles the vertical redistribution automatically when a pane collapses
- Collapse state persists via the `*Collapsed` settings

If all three panes are collapsed, the user still sees three header rows stacked (each can be expanded by clicking). No special "all collapsed" state needed.

## Focus Behavior

### Setting focus

- Clicking anywhere inside a pane's content area sets `focusedPane.focused = paneID`
- Implementation: `PaneShell` wraps its content in a `.contentShape(Rectangle())` + `.onTapGesture { focusedPane.focused = paneID }`
- Note: individual interactive elements (buttons, text fields) inside the content should still work — `onTapGesture` only triggers when the tap isn't consumed by a child view
- Clicking the header row to toggle collapse does *not* change focus (toggle is its own gesture)

### Visual indicator

- Focused pane: the `PaneShell`'s outer frame gets a `.overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))`
- Unfocused panes: no overlay (or a clear-color overlay to prevent layout shift)

### Losing focus

- Clicking another pane transfers focus
- Clicking outside all three panes (e.g., on the control bar) does *not* clear focus — focus persists as long as a pane was last clicked. This means the View menu zoom commands always have a sensible target once the user has interacted with any pane.
- On session start, focus defaults to `nil` until the user clicks a pane

## Hiding the Floating Suggestion Panel

The floating overlay, status bar, and `OverlayManager` wiring are *commented out*, not deleted:

1. In `ContentView.swift`, the "Suggestion panel status" block (currently lines ~170-193) is wrapped in a multi-line comment `/* ... */` with a leading comment `// NOTE: Floating suggestion panel disabled in favor of inline Suggestions pane. See StackedPanesView.`
2. The `OverlayManager` and `MiniBarManager` `@State` declarations at the top of `ContentView` stay — SwiftUI doesn't render them, but the references compile. If any callbacks reference `overlayManager`, those get commented too.
3. The `SuggestionPanelContent.swift`, `OverlayManager.swift`, and related files are untouched.
4. The `suggestionPanelEnabled` and `suggestionsAlwaysOnTop` settings stay in `AppSettings` but are no longer read by ContentView. The Intelligence settings tab UI that exposes them stays visible for now (restoration is just uncommenting).

This leaves the floating panel as a dormant feature that can be restored by uncommenting a single block, without disturbing the intelligence layer that still populates the data.

## Files to Modify / Create

| File | Change |
|---|---|
| **New:** `OpenOats/Sources/OpenOats/Views/StackedPanesView.swift` | Top-level VSplitView wrapper containing three `PaneShell`s |
| **New:** `OpenOats/Sources/OpenOats/Views/PaneShell.swift` | Reusable disclosure-group wrapper with click-to-focus and focus border |
| **New:** `OpenOats/Sources/OpenOats/Views/InlineSuggestionsView.swift` | Inline renderer for the suggestions array (adapted from SuggestionPanelContent) |
| **New:** `OpenOats/Sources/OpenOats/Views/FocusedPaneStore.swift` | Small `@Observable` class holding the focused pane ID and `PaneID` enum |
| `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` | Add `zoom: Double` parameter, apply to body text and bullets |
| `OpenOats/Sources/OpenOats/Views/TranscriptView.swift` | Add `zoom: Double` parameter, apply to utterance text |
| `OpenOats/Sources/OpenOats/Views/ContentView.swift` | Replace HSplitView block with `StackedPanesView`. Comment out suggestion panel status bar. Read `FocusedPaneStore` from environment. |
| `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift` | Add `FocusedPaneStore` `@State`, inject via `.environment()`, add `CommandMenu("View")` with zoom commands |
| `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift` | Add six new properties: `transcriptZoom`, `summaryZoom`, `suggestionsZoom`, `transcriptCollapsed`, `summaryCollapsed`, `suggestionsCollapsed` |

## Files NOT Modified

- `SuggestionPanelContent.swift`, `OverlayManager.swift`, `MiniBarManager.swift` — floating panel code stays dormant but compilable
- `SettingsView.swift` — the existing "Live Summary" toggle and "Classic Suggestions" toggles stay; no new settings UI for zoom/collapse (they're controlled by the pane headers and keyboard shortcuts, not a settings panel)
- Intelligence layer (`LiveSummaryEngine`, `SuggestionEngine`, `TranscriptStore`) — entirely unchanged

## Risks

1. **VSplitView behavior with collapsing children:** SwiftUI's `VSplitView` may not redistribute space cleanly when a child's height changes dramatically (expanded → collapsed). Mitigation: use `.frame(minHeight:, idealHeight:, maxHeight:)` carefully; if `VSplitView` fights us, fall back to a custom `VStack` with `GeometryReader` and manual divider drag handling. Try the simple approach first.
2. **Click-to-focus conflicts with content interactions:** Tapping a button, selectable text, or text field inside a pane shouldn't fire both the button action *and* the focus-setting gesture. SwiftUI's gesture resolution typically handles this correctly (child gestures take priority), but needs verification.
3. **Menu command targeting:** SwiftUI's `.commands` closure runs in a context that doesn't always have live access to observable state. Using an `@Observable` class injected via `.environment()` should work, but if it doesn't, fall back to reading the focused pane via a `@FocusedValue` or a notification-based bridge.
4. **Zoom bounds visual feedback:** When at min/max zoom, further Cmd+/- presses silently clamp. The menu items should become `.disabled(...)` when clamped — this requires the menu to know the current focused pane's zoom level, which works naturally via the same environment-provided store and settings bindable.
5. **Collapsed pane during session start:** If all three panes are collapsed at session start, the user sees three thin headers and no content. This is the user's explicit choice (they collapsed them); no special handling needed.

## Non-Goals

- Drag-and-drop reordering of panes (order is fixed)
- Horizontal arrangement option (vertical only)
- Per-pane color themes or styling customization
- Removing or significantly modifying the existing floating panel code (commented out only)
- Changing the intelligence layer, engines, or suggestion pipeline
- Adding new data to the suggestions pane — it shows whatever `LiveSessionState.suggestions` already contains
