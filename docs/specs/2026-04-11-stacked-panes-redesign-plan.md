# Stacked Panes UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current mixed inline/floating UI with three stacked inline panes (Transcript, Summary, Suggestions) that are collapsible, vertically resizable, per-pane zoomable via Cmd+/-/0, and comment out the floating suggestion panel wiring.

**Architecture:** A new `StackedPanesView` wraps three panes in a `VSplitView`. Each pane uses a reusable `PaneShell` for the disclosure header and focus behavior. A shared `FocusedPaneStore` `@Observable` object routes keyboard/menu commands to the focused pane. Zoom and collapse state persist via new `AppSettings` properties.

**Tech Stack:** Swift 6.2, SwiftUI, `@Observable` pattern, macOS 15+, `VSplitView`, `CommandMenu`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| **New:** `OpenOats/Sources/OpenOats/Views/FocusedPaneStore.swift` | `PaneID` enum and `FocusedPaneStore` observable class |
| **New:** `OpenOats/Sources/OpenOats/Views/PaneShell.swift` | Reusable pane wrapper with disclosure header, click-to-focus, focus border |
| **New:** `OpenOats/Sources/OpenOats/Views/InlineSuggestionsView.swift` | Inline list renderer for `[Suggestion]` with zoom parameter |
| **New:** `OpenOats/Sources/OpenOats/Views/StackedPanesView.swift` | Top-level `VSplitView` wrapping the three `PaneShell`s |
| `OpenOats/Sources/OpenOats/Views/TranscriptView.swift` | Accept `zoom: Double` parameter, apply to utterance body text |
| `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` | Accept `zoom: Double` parameter, apply to summary body + key points |
| `OpenOats/Sources/OpenOats/Views/ContentView.swift` | Replace HSplitView block with StackedPanesView. Comment out suggestion panel status bar block. Read FocusedPaneStore from environment. |
| `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift` | Create FocusedPaneStore @State, inject via .environment(), add View CommandMenu with zoom shortcuts |
| `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift` | Add 6 new settings: transcriptZoom/summaryZoom/suggestionsZoom (Double) + transcriptCollapsed/summaryCollapsed/suggestionsCollapsed (Bool) |

---

### Task 1: Create FocusedPaneStore and PaneID

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/FocusedPaneStore.swift`

- [ ] **Step 1: Create the file**

Create `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Views/FocusedPaneStore.swift` with:

```swift
import Foundation
import Observation

/// Identifies one of the three stacked panes in the main window.
enum PaneID: String, CaseIterable, Sendable {
    case transcript
    case summary
    case suggestions
}

/// Tracks which pane currently has focus for purposes of keyboard/menu commands
/// (e.g., Cmd+/- zoom targets the focused pane).
///
/// Injected into the environment by `OpenOatsApp` so both `ContentView` (to
/// show a focus border) and the `View` menu's command handlers can read it.
@Observable
@MainActor
final class FocusedPaneStore {
    var focused: PaneID? = nil

    init() {}
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!` (the file has no dependencies yet).

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/FocusedPaneStore.swift
git commit -m "feat: add FocusedPaneStore and PaneID for stacked panes focus tracking"
```

---

### Task 2: Add zoom and collapse settings

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`

- [ ] **Step 1: Add six new property blocks**

In `SettingsStore.swift`, find the `showLiveSummaryPanel` property block (added in a previous feature). Immediately after its closing brace, add:

```swift
    @ObservationIgnored nonisolated(unsafe) private var _transcriptZoom: Double
    var transcriptZoom: Double {
        get { access(keyPath: \.transcriptZoom); return _transcriptZoom }
        set {
            withMutation(keyPath: \.transcriptZoom) {
                _transcriptZoom = newValue
                defaults.set(newValue, forKey: "transcriptZoom")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _summaryZoom: Double
    var summaryZoom: Double {
        get { access(keyPath: \.summaryZoom); return _summaryZoom }
        set {
            withMutation(keyPath: \.summaryZoom) {
                _summaryZoom = newValue
                defaults.set(newValue, forKey: "summaryZoom")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _suggestionsZoom: Double
    var suggestionsZoom: Double {
        get { access(keyPath: \.suggestionsZoom); return _suggestionsZoom }
        set {
            withMutation(keyPath: \.suggestionsZoom) {
                _suggestionsZoom = newValue
                defaults.set(newValue, forKey: "suggestionsZoom")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcriptCollapsed: Bool
    var transcriptCollapsed: Bool {
        get { access(keyPath: \.transcriptCollapsed); return _transcriptCollapsed }
        set {
            withMutation(keyPath: \.transcriptCollapsed) {
                _transcriptCollapsed = newValue
                defaults.set(newValue, forKey: "transcriptCollapsed")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _summaryCollapsed: Bool
    var summaryCollapsed: Bool {
        get { access(keyPath: \.summaryCollapsed); return _summaryCollapsed }
        set {
            withMutation(keyPath: \.summaryCollapsed) {
                _summaryCollapsed = newValue
                defaults.set(newValue, forKey: "summaryCollapsed")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _suggestionsCollapsed: Bool
    var suggestionsCollapsed: Bool {
        get { access(keyPath: \.suggestionsCollapsed); return _suggestionsCollapsed }
        set {
            withMutation(keyPath: \.suggestionsCollapsed) {
                _suggestionsCollapsed = newValue
                defaults.set(newValue, forKey: "suggestionsCollapsed")
            }
        }
    }
```

- [ ] **Step 2: Initialize the six new settings in init(storage:)**

In the same file, find the `init(storage:)` method. Locate the `showLiveSummaryPanel` init block (the `if defaults.object(forKey: "showLiveSummaryPanel") == nil { ... }` block). Immediately after it, add:

```swift
        // Zoom levels default to 1.0 (no zoom)
        if defaults.object(forKey: "transcriptZoom") != nil {
            self._transcriptZoom = defaults.double(forKey: "transcriptZoom")
        } else {
            self._transcriptZoom = 1.0
        }

        if defaults.object(forKey: "summaryZoom") != nil {
            self._summaryZoom = defaults.double(forKey: "summaryZoom")
        } else {
            self._summaryZoom = 1.0
        }

        if defaults.object(forKey: "suggestionsZoom") != nil {
            self._suggestionsZoom = defaults.double(forKey: "suggestionsZoom")
        } else {
            self._suggestionsZoom = 1.0
        }

        // Collapse state defaults to expanded (false)
        self._transcriptCollapsed = defaults.bool(forKey: "transcriptCollapsed")
        self._summaryCollapsed = defaults.bool(forKey: "summaryCollapsed")
        self._suggestionsCollapsed = defaults.bool(forKey: "suggestionsCollapsed")
```

- [ ] **Step 3: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift
git commit -m "feat: add per-pane zoom and collapse settings"
```

---

### Task 3: Create PaneShell

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/PaneShell.swift`

- [ ] **Step 1: Create the file**

Create `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Views/PaneShell.swift` with:

```swift
import SwiftUI

/// A reusable wrapper for one of the three stacked panes in the main window.
///
/// Provides:
/// - A disclosure header row (chevron + title + optional badge) that toggles `isCollapsed`.
/// - Click-to-focus: tapping inside the content area sets `focusedPane.focused = paneID`.
/// - A thin accent-colored border around the content when this pane is focused.
/// - Collapsed state hides content, leaving only the header row visible.
struct PaneShell<Content: View>: View {
    let title: String
    let badge: String?
    let paneID: PaneID
    @Binding var isCollapsed: Bool
    @Bindable var focusedPane: FocusedPaneStore
    let content: () -> Content

    init(
        title: String,
        badge: String? = nil,
        paneID: PaneID,
        isCollapsed: Binding<Bool>,
        focusedPane: FocusedPaneStore,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.badge = badge
        self.paneID = paneID
        self._isCollapsed = isCollapsed
        self.focusedPane = focusedPane
        self.content = content
    }

    private var isFocused: Bool {
        focusedPane.focused == paneID
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedPane.focused = paneID
                    }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if let badge {
                Text(badge)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                isCollapsed.toggle()
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/PaneShell.swift
git commit -m "feat: add PaneShell reusable disclosure wrapper with focus support"
```

---

### Task 4: Create InlineSuggestionsView

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/InlineSuggestionsView.swift`

- [ ] **Step 1: Create the file**

Create `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Views/InlineSuggestionsView.swift` with:

```swift
import SwiftUI

/// Inline renderer for the suggestions array in the stacked panes view.
/// Displays each `Suggestion` as a card with its text and optional KB source
/// breadcrumbs. Accepts a zoom multiplier for the body text.
struct InlineSuggestionsView: View {
    let suggestions: [Suggestion]
    let zoom: Double

    var body: some View {
        if suggestions.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(suggestions) { suggestion in
                        card(for: suggestion)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("Waiting for suggestions...")
                .font(.system(size: 12 * zoom))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, 24)
    }

    @ViewBuilder
    private func card(for suggestion: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let firstHit = suggestion.kbHits.first, !firstHit.sourceFile.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9 * zoom))
                    Text(breadcrumb(for: firstHit))
                        .font(.system(size: 10 * zoom))
                        .lineLimit(1)
                }
                .foregroundStyle(.tertiary)
            }

            if let md = try? AttributedString(
                markdown: suggestion.text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(md)
                    .font(.system(size: 13 * zoom))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(suggestion.text)
                    .font(.system(size: 13 * zoom))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func breadcrumb(for hit: KBResult) -> String {
        if let header = hit.headerContext, !header.isEmpty {
            return "\(hit.sourceFile) > \(header)"
        }
        return hit.sourceFile
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -10
```

Expected: `Build complete!`. If there's an error about `KBResult` members (`sourceFile`, `headerContext`), those match how `SuggestionPanelContent.swift` used them — verify with `grep`.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/InlineSuggestionsView.swift
git commit -m "feat: add InlineSuggestionsView for stacked panes"
```

---

### Task 5: Add zoom parameter to TranscriptView

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/TranscriptView.swift`

- [ ] **Step 1: Add zoom parameter**

In `TranscriptView.swift`, change the struct declaration (around line 3-7):

```swift
struct TranscriptView: View {
    let utterances: [Utterance]
    let volatileYouText: String
    let volatileThemText: String
    var showSearch: Bool = false
```

Add a `zoom` parameter:

```swift
struct TranscriptView: View {
    let utterances: [Utterance]
    let volatileYouText: String
    let volatileThemText: String
    var zoom: Double = 1.0
    var showSearch: Bool = false
```

- [ ] **Step 2: Pass zoom into UtteranceBubble**

In the same file, find the `ForEach` inside `transcriptScrollView` (around line 82-89). It looks like:

```swift
                        ForEach(0..<visible.count, id: \.self) { index in
                            let utterance = visible[index]
                            UtteranceBubble(
                                utterance: utterance,
                                showTimestamp: shouldShowTimestamp(at: index, in: visible)
                            )
                            .id(utterance.id)
                        }
```

Replace with:

```swift
                        ForEach(0..<visible.count, id: \.self) { index in
                            let utterance = visible[index]
                            UtteranceBubble(
                                utterance: utterance,
                                showTimestamp: shouldShowTimestamp(at: index, in: visible),
                                zoom: zoom
                            )
                            .id(utterance.id)
                        }
```

- [ ] **Step 3: Pass zoom into VolatileIndicator**

In the same file, find the two `VolatileIndicator(text:speaker:)` calls (around lines 93-99):

```swift
                            if !volatileYouText.isEmpty {
                                VolatileIndicator(text: volatileYouText, speaker: .you)
                                    .id("volatile-you")
                            }

                            if !volatileThemText.isEmpty {
                                VolatileIndicator(text: volatileThemText, speaker: .them)
                                    .id("volatile-them")
                            }
```

Replace with:

```swift
                            if !volatileYouText.isEmpty {
                                VolatileIndicator(text: volatileYouText, speaker: .you, zoom: zoom)
                                    .id("volatile-you")
                            }

                            if !volatileThemText.isEmpty {
                                VolatileIndicator(text: volatileThemText, speaker: .them, zoom: zoom)
                                    .id("volatile-them")
                            }
```

- [ ] **Step 4: Update UtteranceBubble to accept and apply zoom**

In the same file, find `private struct UtteranceBubble` (around line 167). Replace the entire struct with:

```swift
private struct UtteranceBubble: View {
    let utterance: Utterance
    var showTimestamp: Bool = true
    var zoom: Double = 1.0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showTimestamp {
                Text(timestampFormatter.string(from: utterance.timestamp))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .trailing)
            } else {
                Spacer()
                    .frame(width: 34)
            }

            Text(utterance.speaker.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(utterance.speaker.color)
                .frame(minWidth: 36, alignment: .trailing)

            Text(utterance.displayText)
                .font(.system(size: 13 * zoom))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}
```

- [ ] **Step 5: Update VolatileIndicator to accept and apply zoom**

In the same file, find `private struct VolatileIndicator` (around line 196). Replace the entire struct with:

```swift
private struct VolatileIndicator: View {
    let text: String
    let speaker: Speaker
    var zoom: Double = 1.0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Spacer()
                .frame(width: 34)

            Text(speaker.displayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(speaker.color)
                .frame(minWidth: 36, alignment: .trailing)

            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 13 * zoom))
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(speaker.color)
                    .frame(width: 4, height: 4)
                    .opacity(0.6)
            }
        }
        .opacity(0.6)
    }
}
```

- [ ] **Step 6: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -10
```

Expected: `Build complete!`. Any call site that doesn't pass `zoom` continues to work because of the default value `= 1.0`.

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/TranscriptView.swift
git commit -m "feat: add zoom parameter to TranscriptView"
```

---

### Task 6: Add zoom parameter to LiveSummaryPanel

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift`

- [ ] **Step 1: Add zoom parameter to struct declaration**

In `LiveSummaryPanel.swift`, find the struct declaration (around lines 3-6):

```swift
struct LiveSummaryPanel: View {
    let summary: String
    let keyPoints: [String]
    let isGenerating: Bool
```

Change it to:

```swift
struct LiveSummaryPanel: View {
    let summary: String
    let keyPoints: [String]
    let isGenerating: Bool
    var zoom: Double = 1.0
```

- [ ] **Step 2: Apply zoom to summary body text**

In `summarySection` (around line 54), find:

```swift
            Text(summary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
```

Replace with:

```swift
            Text(summary)
                .font(.system(size: 13 * zoom))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 3: Apply zoom to key point bullets**

In `keyPointsSection` (around line 78), find the `ForEach` block. It currently looks like:

```swift
            ForEach(keyPoints, id: \.self) { point in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(point)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
```

Replace with:

```swift
            ForEach(keyPoints, id: \.self) { point in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.system(size: 13 * zoom))
                        .foregroundStyle(.secondary)
                    Text(point)
                        .font(.system(size: 13 * zoom))
                        .fixedSize(horizontal: false, vertical: true)
                }
```

- [ ] **Step 4: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -10
```

Expected: `Build complete!`. Existing call sites still compile because of the default value `= 1.0`.

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift
git commit -m "feat: add zoom parameter to LiveSummaryPanel"
```

---

### Task 7: Create StackedPanesView

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/StackedPanesView.swift`

- [ ] **Step 1: Create the file**

Create `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Views/StackedPanesView.swift` with:

```swift
import SwiftUI

/// Top-level view containing the three stacked panes (Transcript, Summary,
/// Suggestions) during a live session. Uses VSplitView for draggable dividers.
struct StackedPanesView: View {
    let controllerState: LiveSessionState
    @Bindable var settings: AppSettings
    @Bindable var focusedPane: FocusedPaneStore

    var body: some View {
        VSplitView {
            PaneShell(
                title: "Transcript",
                badge: controllerState.liveTranscript.isEmpty ? nil : "(\(controllerState.liveTranscript.count))",
                paneID: .transcript,
                isCollapsed: $settings.transcriptCollapsed,
                focusedPane: focusedPane
            ) {
                TranscriptView(
                    utterances: controllerState.liveTranscript,
                    volatileYouText: controllerState.volatileYouText,
                    volatileThemText: controllerState.volatileThemText,
                    zoom: settings.transcriptZoom
                )
            }
            .frame(minHeight: settings.transcriptCollapsed ? 28 : 80)

            PaneShell(
                title: "Meeting Summary",
                badge: nil,
                paneID: .summary,
                isCollapsed: $settings.summaryCollapsed,
                focusedPane: focusedPane
            ) {
                LiveSummaryPanel(
                    summary: controllerState.liveSummary,
                    keyPoints: controllerState.liveKeyPoints,
                    isGenerating: controllerState.liveSummaryIsGenerating,
                    zoom: settings.summaryZoom
                )
            }
            .frame(minHeight: settings.summaryCollapsed ? 28 : 80)

            PaneShell(
                title: "Suggestions",
                badge: controllerState.suggestions.isEmpty ? nil : "(\(controllerState.suggestions.count))",
                paneID: .suggestions,
                isCollapsed: $settings.suggestionsCollapsed,
                focusedPane: focusedPane
            ) {
                InlineSuggestionsView(
                    suggestions: controllerState.suggestions,
                    zoom: settings.suggestionsZoom
                )
            }
            .frame(minHeight: settings.suggestionsCollapsed ? 28 : 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -10
```

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/StackedPanesView.swift
git commit -m "feat: add StackedPanesView with three VSplitView panes"
```

---

### Task 8: Wire FocusedPaneStore into OpenOatsApp with View menu

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift`

- [ ] **Step 1: Add @State for focused pane store**

In `OpenOatsApp.swift`, in the `OpenOatsRootApp` struct (around lines 8-24), after the existing `@State` declarations, add:

```swift
    @State private var focusedPane = FocusedPaneStore()
```

The block should now look like:

```swift
public struct OpenOatsRootApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var settings: AppSettings
    @State private var coordinator: AppCoordinator
    @State private var container: AppContainer
    @State private var focusedPane = FocusedPaneStore()
    private let updaterController: AppUpdaterController
    private let defaults: UserDefaults
```

- [ ] **Step 2: Inject focusedPane into the main window environment**

Find the `Window("OpenOats", id: "main")` scene block (around line 27). It currently has:

```swift
        Window("OpenOats", id: "main") {
            ContentView(settings: settings)
                .environment(container)
                .environment(coordinator)
                .defaultAppStorage(defaults)
                .onAppear {
```

Add `.environment(focusedPane)` after `.environment(coordinator)`:

```swift
        Window("OpenOats", id: "main") {
            ContentView(settings: settings)
                .environment(container)
                .environment(coordinator)
                .environment(focusedPane)
                .defaultAppStorage(defaults)
                .onAppear {
```

- [ ] **Step 3: Add View CommandMenu with zoom commands**

Find the `.commands { ... }` block (around line 66). It currently contains a `CommandGroup(after: .appInfo) { ... }`. After the closing brace of that CommandGroup but still inside the `.commands { }` closure, add a new `CommandMenu("View")`:

```swift
        .commands {
            CommandGroup(after: .appInfo) {
                if case .live = container.mode {
                    CheckForUpdatesView(updater: updaterController.updater)

                    Divider()
                }

                Button("Toggle Meeting") {
                    appDelegate.toggleMeeting()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Past Meetings") {
                    openNotesWindow()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Import Meeting Recording...") {
                    importMeetingRecording()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(coordinator.isRecording || isBatchEngineBusy)

                Button("GitHub Repository...") {
                    if let url = URL(string: "https://github.com/yazinsai/OpenOats") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            CommandMenu("View") {
                Button("Zoom In") {
                    adjustZoom(by: 0.1)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(focusedPane.focused == nil)

                Button("Zoom Out") {
                    adjustZoom(by: -0.1)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(focusedPane.focused == nil)

                Button("Reset Zoom") {
                    resetZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(focusedPane.focused == nil)
            }
        }
```

- [ ] **Step 4: Add zoom helper methods to OpenOatsRootApp**

In the same file, find the `extension OpenOatsRootApp` block at the bottom (around line 124). Inside that extension, add two private helper methods:

```swift
    private func adjustZoom(by delta: Double) {
        guard let pane = focusedPane.focused else { return }
        let minZoom = 0.7
        let maxZoom = 2.0
        switch pane {
        case .transcript:
            settings.transcriptZoom = min(maxZoom, max(minZoom, settings.transcriptZoom + delta))
        case .summary:
            settings.summaryZoom = min(maxZoom, max(minZoom, settings.summaryZoom + delta))
        case .suggestions:
            settings.suggestionsZoom = min(maxZoom, max(minZoom, settings.suggestionsZoom + delta))
        }
    }

    private func resetZoom() {
        guard let pane = focusedPane.focused else { return }
        switch pane {
        case .transcript: settings.transcriptZoom = 1.0
        case .summary: settings.summaryZoom = 1.0
        case .suggestions: settings.suggestionsZoom = 1.0
        }
    }
```

- [ ] **Step 5: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -10
```

Expected: `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/OpenOatsApp.swift
git commit -m "feat: add FocusedPaneStore injection and View menu with zoom commands"
```

---

### Task 9: Integrate StackedPanesView into ContentView and comment out suggestion status bar

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/ContentView.swift`

- [ ] **Step 1: Read FocusedPaneStore from environment**

In `ContentView.swift`, find the `@Environment(AppCoordinator.self)` line (around line 14):

```swift
    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
```

Add the `FocusedPaneStore` environment read:

```swift
    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(FocusedPaneStore.self) private var focusedPane
    @Environment(\.openWindow) private var openWindow
```

- [ ] **Step 2: Comment out the suggestion panel status bar block**

Find the "Suggestion panel status" block inside `rootContent` (around lines 170-193). It currently looks like:

```swift
            // Suggestion panel status
            if controllerState.isRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controllerState.isGeneratingSuggestions ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text("\(settings.sidebarMode == .sidecast ? "Sidecast" : "Suggestions") \(overlayManager.isVisible ? "visible" : "hidden")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        toggleOverlay()
                    } label: {
                        Text(overlayManager.isVisible ? "Hide Panel" : "Show Panel")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }
```

Wrap it in a multi-line comment:

```swift
            // NOTE: Floating suggestion panel disabled in favor of inline Suggestions pane.
            // To restore, uncomment this block and the OverlayManager wiring in .task.
            /*
            // Suggestion panel status
            if controllerState.isRunning {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controllerState.isGeneratingSuggestions ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text("\(settings.sidebarMode == .sidecast ? "Sidecast" : "Suggestions") \(overlayManager.isVisible ? "visible" : "hidden")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        toggleOverlay()
                    } label: {
                        Text(overlayManager.isVisible ? "Hide Panel" : "Show Panel")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
            }
            */
```

- [ ] **Step 3: Replace the HSplitView/transcript block with StackedPanesView**

Find the transcript/summary layout block (around lines 197-213). It currently looks like:

```swift
            // Transcript + optional live summary sidebar
            if controllerState.showLiveTranscript {
                if controllerState.isRunning && settings.showLiveSummaryPanel {
                    HSplitView {
                        transcriptSection(controllerState: controllerState)
                            .frame(minWidth: 200)
                        LiveSummaryPanel(
                            summary: controllerState.liveSummary,
                            keyPoints: controllerState.liveKeyPoints,
                            isGenerating: controllerState.liveSummaryIsGenerating
                        )
                        .frame(minWidth: 200, idealWidth: 280)
                    }
                    .frame(minHeight: 150)
                } else {
                    transcriptSection(controllerState: controllerState)
                }
            }
```

Replace it with:

```swift
            // Stacked panes during live session
            if controllerState.isRunning {
                StackedPanesView(
                    controllerState: controllerState,
                    settings: settings,
                    focusedPane: focusedPane
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
```

- [ ] **Step 4: Remove the now-unused transcriptSection helper method**

Find the `@ViewBuilder private func transcriptSection(...)` method in `ContentView.swift` (it was added in a previous task for the old HSplitView layout; now unused). It looks like:

```swift
    @ViewBuilder
    private func transcriptSection(controllerState: LiveSessionState) -> some View {
        DisclosureGroup(isExpanded: $isTranscriptExpanded) {
            IsolatedTranscriptWrapper(state: controllerState)
                .frame(height: 150)
        } label: {
            HStack(spacing: 6) {
                Text("Transcript")
                    .font(.system(size: 12, weight: .medium))
                ...
```

Delete the entire method (from `@ViewBuilder` through its closing brace). Also delete the `IsolatedTranscriptWrapper` if it is no longer referenced by any other code. Check:

```bash
cd /Users/jja/Projects/active/openoats && grep -rn "IsolatedTranscriptWrapper" OpenOats/Sources/
```

If it's only defined and referenced inside `ContentView.swift`, delete the struct definition as well. If it's used elsewhere, leave it.

- [ ] **Step 5: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -15
```

Expected: `Build complete!`. If there are errors about unused variables (like `isTranscriptExpanded`), leave them — they'll be cleaned up in Task 10.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/ContentView.swift
git commit -m "feat: integrate StackedPanesView and comment out floating panel status bar"
```

---

### Task 10: Cleanup and manual integration test

**Files:** None (cleanup + testing only)

- [ ] **Step 1: Grep for remaining unused references**

Run these searches to identify any dead code left behind:

```bash
cd /Users/jja/Projects/active/openoats && grep -rn "isTranscriptExpanded" OpenOats/Sources/
cd /Users/jja/Projects/active/openoats && grep -rn "transcriptSection" OpenOats/Sources/
cd /Users/jja/Projects/active/openoats && grep -rn "IsolatedTranscriptWrapper" OpenOats/Sources/
```

If `isTranscriptExpanded` is only referenced by `@AppStorage` declaration (no more usages), it can be removed. Same for the others.

- [ ] **Step 2: Remove unused references (if any)**

If `isTranscriptExpanded` is declared in `ContentView.swift` but unused after Task 9, delete its declaration line:

```swift
    @AppStorage("isTranscriptExpanded") private var isTranscriptExpanded = true
```

- [ ] **Step 3: Final build**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!` with no warnings.

- [ ] **Step 4: Commit cleanup**

If any cleanup happened:
```bash
git add -A
git commit -m "chore: remove dead references after stacked panes integration"
```

- [ ] **Step 5: Build and install for testing**

Run:
```bash
cd /Users/jja/Projects/active/openoats && ./scripts/build_swift_app.sh
```

Expected: App builds, signs, and installs to `/Applications/OpenOats.app`.

- [ ] **Step 6: Launch from command line to catch logs**

Run:
```bash
/Applications/OpenOats.app/Contents/MacOS/OpenOats
```

Keep the terminal visible.

- [ ] **Step 7: Verify initial state (no session)**

With no session running, verify:
- Main window shows the idle layout (no three-pane view visible)
- No "Suggestions visible/hidden" status bar appears
- Menu bar has a new "View" menu with Zoom In, Zoom Out, Reset Zoom items
- All three zoom items are disabled (no pane focused yet)

- [ ] **Step 8: Verify stacked panes appear on session start**

Click Idle → Live. Verify:
- Three panes appear in the main window: Transcript, Meeting Summary, Suggestions (in that order, top to bottom)
- Each pane has a disclosure header with a chevron
- Draggable dividers separate the panes
- Transcript pane shows "Waiting for utterances..." or similar empty state
- Summary pane shows "Listening..."
- Suggestions pane shows "Waiting for suggestions..."

- [ ] **Step 9: Verify collapse behavior**

Click the header of each pane in turn. Verify:
- Clicking toggles the chevron (▼ ↔ ▶) and hides/shows the content
- When collapsed, only the header row is visible
- Other panes grow to fill the freed space
- Collapse state persists: close the session and restart it; the panes should be in the same collapsed/expanded state
- Quit and relaunch the app; state should still persist

- [ ] **Step 10: Verify resize behavior**

Drag each divider. Verify:
- Dividers move smoothly
- Panes respect their minHeight (can't collapse below ~28pt even when dragging)
- Content reflows correctly

- [ ] **Step 11: Verify click-to-focus**

Click inside the transcript pane content area. Verify:
- A thin accent-colored border appears around the transcript pane
- Click inside the summary pane; the border moves to summary, transcript loses border
- Click the header (not content) to toggle collapse; focus does NOT change

- [ ] **Step 12: Verify zoom shortcuts**

Click inside the transcript pane, then press Cmd+=. Verify:
- Transcript text grows
- Summary and suggestions text stay the same
- View menu shows the shortcut enabled
- Cmd+- shrinks it back
- Cmd+0 resets to default
- Zoom persists across app restart

Repeat for summary and suggestions panes.

- [ ] **Step 13: Verify zoom bounds**

In the focused pane, press Cmd+= repeatedly until nothing happens. Verify:
- Zoom stops growing around 2.0x
- Cmd+- repeatedly stops shrinking around 0.7x

- [ ] **Step 14: Verify floating panel is gone**

During a live session, verify:
- No "Show Panel" button in the main window
- No status bar with the colored dot for suggestions
- No floating window appears anywhere on screen
- The inline Suggestions pane still populates (the engine is still running)

- [ ] **Step 15: Commit any fixes**

```bash
git add -A
git commit -m "fix: address issues found during stacked panes testing"
```
