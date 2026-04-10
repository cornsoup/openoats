# Live Summary Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the existing `ConversationState` in a sidebar panel during live calls so users can follow the conversation without reading every transcript line.

**Architecture:** Add a `conversationState` property to `LiveSessionState`, copied from `TranscriptStore` on each polling tick. A new `LiveSummaryPanel` SwiftUI view renders the state with diff highlighting. `ContentView` wraps the transcript and summary panel in an `HSplitView` when a session is live. Two new settings (`showLiveSummaryPanel`, `liveSummarySections`) control visibility and section toggles.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 15+, `@Observable` pattern

---

## File Structure

| File | Responsibility |
|------|---------------|
| `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift` | Add two new settings properties |
| `OpenOats/Sources/OpenOats/Views/SettingsView.swift` | Add "Live Summary" section to Intelligence tab |
| `OpenOats/Sources/OpenOats/App/LiveSessionController.swift` | Add `conversationState` to `LiveSessionState` and copy it in `refreshState()` |
| **New:** `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` | SwiftUI view rendering `ConversationState` sections with diff highlighting |
| `OpenOats/Sources/OpenOats/Views/ContentView.swift` | Wrap transcript + summary panel in `HSplitView` during live sessions |

---

### Task 1: Add settings properties to SettingsStore

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`

- [ ] **Step 1: Add the `showLiveSummaryPanel` backing store and property**

After the existing `_suggestionsAlwaysOnTop` property block (around line 230), add:

```swift
@ObservationIgnored nonisolated(unsafe) private var _showLiveSummaryPanel: Bool
var showLiveSummaryPanel: Bool {
    get { access(keyPath: \.showLiveSummaryPanel); return _showLiveSummaryPanel }
    set {
        withMutation(keyPath: \.showLiveSummaryPanel) {
            _showLiveSummaryPanel = newValue
            defaults.set(newValue, forKey: "showLiveSummaryPanel")
        }
    }
}
```

- [ ] **Step 2: Add the `liveSummarySections` backing store and property**

Immediately after the `showLiveSummaryPanel` property, add:

```swift
@ObservationIgnored nonisolated(unsafe) private var _liveSummarySections: Set<String>
var liveSummarySections: Set<String> {
    get { access(keyPath: \.liveSummarySections); return _liveSummarySections }
    set {
        withMutation(keyPath: \.liveSummarySections) {
            _liveSummarySections = newValue
            let encoded = try? JSONEncoder().encode(Array(newValue))
            defaults.set(encoded, forKey: "liveSummarySections")
        }
    }
}
```

- [ ] **Step 3: Initialize both settings in `init(storage:)`**

In the `init` method, after the `_suggestionsAlwaysOnTop` initialization block (around line 858), add:

```swift
if defaults.object(forKey: "showLiveSummaryPanel") == nil {
    self._showLiveSummaryPanel = true
} else {
    self._showLiveSummaryPanel = defaults.bool(forKey: "showLiveSummaryPanel")
}

if let sectionsData = defaults.data(forKey: "liveSummarySections"),
   let decoded = try? JSONDecoder().decode([String].self, from: sectionsData) {
    self._liveSummarySections = Set(decoded)
} else {
    self._liveSummarySections = ["topic", "summary", "openQuestions", "recentDecisions"]
}
```

- [ ] **Step 4: Build to verify no compiler errors**

Run:
```bash
cd OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: Build succeeds with no errors related to the new properties.

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift
git commit -m "feat: add showLiveSummaryPanel and liveSummarySections settings"
```

---

### Task 2: Add settings UI in SettingsView

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/SettingsView.swift`

- [ ] **Step 1: Add a "Live Summary" section to IntelligenceSettingsTab**

In `IntelligenceSettingsTab`, after the "Classic Suggestions" `Section` block (after line 587), add a new section:

```swift
Section("Live Summary") {
    Toggle("Show live summary panel during calls", isOn: $settings.showLiveSummaryPanel)
        .font(.system(size: 12))
    Text("Displays a real-time summary of the conversation alongside the transcript. Requires an LLM provider to be configured.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

    if settings.showLiveSummaryPanel {
        liveSummarySectionToggle("Topic", key: "topic")
        liveSummarySectionToggle("Summary", key: "summary")
        liveSummarySectionToggle("Open Questions", key: "openQuestions")
        liveSummarySectionToggle("Decisions", key: "recentDecisions")
        liveSummarySectionToggle("Tensions", key: "activeTensions")
        liveSummarySectionToggle("Their Goals", key: "themGoals")
    }
}
```

- [ ] **Step 2: Add the helper method to IntelligenceSettingsTab**

Inside the `IntelligenceSettingsTab` struct, after the `body` computed property, add:

```swift
private func liveSummarySectionToggle(_ label: String, key: String) -> some View {
    Toggle(label, isOn: Binding(
        get: { settings.liveSummarySections.contains(key) },
        set: { enabled in
            var sections = settings.liveSummarySections
            if enabled {
                sections.insert(key)
            } else {
                sections.remove(key)
            }
            settings.liveSummarySections = sections
        }
    ))
    .font(.system(size: 12))
    .padding(.leading, 16)
}
```

- [ ] **Step 3: Build to verify no compiler errors**

Run:
```bash
cd OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/SettingsView.swift
git commit -m "feat: add Live Summary section to Intelligence settings tab"
```

---

### Task 3: Expose ConversationState on LiveSessionState

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`

- [ ] **Step 1: Add `conversationState` property to `LiveSessionState`**

In the `LiveSessionState` class (around line 10-35), add a new property after `scratchpadText`:

```swift
var conversationState: ConversationState = .empty
```

- [ ] **Step 2: Copy conversationState in `refreshState()`**

In the `refreshState(settings:)` method, after the `suggestions` array comparison block (after line 578), add:

```swift
let nextConversationState = coordinator.transcriptStore.conversationState
if state.conversationState.lastUpdatedAt != nextConversationState.lastUpdatedAt {
    state.conversationState = nextConversationState
}
```

This uses `lastUpdatedAt` as a cheap change-detection sentinel — avoids comparing all fields on every 250ms tick.

- [ ] **Step 3: Build to verify no compiler errors**

Run:
```bash
cd OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/LiveSessionController.swift
git commit -m "feat: expose ConversationState on LiveSessionState"
```

---

### Task 4: Create LiveSummaryPanel view

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift`

- [ ] **Step 1: Create the LiveSummaryPanel view file**

Create `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` with the full implementation:

```swift
import SwiftUI

struct LiveSummaryPanel: View {
    let conversationState: ConversationState
    let visibleSections: Set<String>

    @State private var previousState: ConversationState = .empty
    @State private var highlightedSections: Set<String> = []
    @State private var highlightedItems: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if visibleSections.contains("topic") {
                    topicSection
                }
                if visibleSections.contains("summary") {
                    summarySection
                }
                if visibleSections.contains("openQuestions") {
                    listSection(
                        title: "Open Questions",
                        items: conversationState.openQuestions,
                        previousItems: previousState.openQuestions,
                        sectionKey: "openQuestions"
                    )
                }
                if visibleSections.contains("recentDecisions") {
                    listSection(
                        title: "Decisions",
                        items: conversationState.recentDecisions,
                        previousItems: previousState.recentDecisions,
                        sectionKey: "recentDecisions"
                    )
                }
                if visibleSections.contains("activeTensions") {
                    listSection(
                        title: "Tensions",
                        items: conversationState.activeTensions,
                        previousItems: previousState.activeTensions,
                        sectionKey: "activeTensions"
                    )
                }
                if visibleSections.contains("themGoals") {
                    listSection(
                        title: "Their Goals",
                        items: conversationState.themGoals,
                        previousItems: previousState.themGoals,
                        sectionKey: "themGoals"
                    )
                }

                if visibleSections.isEmpty {
                    Text("No sections enabled")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(12)
        }
        .onChange(of: conversationState.lastUpdatedAt) { _, _ in
            computeDiffs()
        }
    }

    // MARK: - Sections

    private var topicSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversationState.currentTopic.isEmpty ? "Waiting for conversation..." : conversationState.currentTopic)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(conversationState.currentTopic.isEmpty ? .tertiary : .primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightBackground(for: "topic"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summary")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if conversationState.shortSummary.isEmpty {
                Text("None yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                Text(conversationState.shortSummary)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightBackground(for: "summary"))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func listSection(title: String, items: [String], previousItems: [String], sectionKey: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("None yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(itemHighlightBackground(for: item, in: sectionKey))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Diff Highlighting

    private func computeDiffs() {
        let oldState = previousState
        var newHighlightedSections: Set<String> = []
        var newHighlightedItems: Set<String> = []

        if conversationState.currentTopic != oldState.currentTopic {
            newHighlightedSections.insert("topic")
        }
        if conversationState.shortSummary != oldState.shortSummary {
            newHighlightedSections.insert("summary")
        }

        let listFields: [(String, [String], [String])] = [
            ("openQuestions", conversationState.openQuestions, oldState.openQuestions),
            ("recentDecisions", conversationState.recentDecisions, oldState.recentDecisions),
            ("activeTensions", conversationState.activeTensions, oldState.activeTensions),
            ("themGoals", conversationState.themGoals, oldState.themGoals),
        ]
        for (sectionKey, current, previous) in listFields {
            let previousSet = Set(previous)
            for item in current where !previousSet.contains(item) {
                newHighlightedItems.insert("\(sectionKey):\(item)")
            }
        }

        previousState = conversationState

        withAnimation(.easeIn(duration: 0.2)) {
            highlightedSections = newHighlightedSections
            highlightedItems = newHighlightedItems
        }

        // Fade out highlights after 1.5 seconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) {
                highlightedSections = []
                highlightedItems = []
            }
        }
    }

    private func highlightBackground(for sectionKey: String) -> some ShapeStyle {
        highlightedSections.contains(sectionKey)
            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
            : AnyShapeStyle(Color.clear)
    }

    private func itemHighlightBackground(for item: String, in sectionKey: String) -> some ShapeStyle {
        highlightedItems.contains("\(sectionKey):\(item)")
            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
            : AnyShapeStyle(Color.clear)
    }
}
```

- [ ] **Step 2: Build to verify no compiler errors**

Run:
```bash
cd OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: Build succeeds. The view references `ConversationState` which is already defined in `Domain/Utterance.swift`.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift
git commit -m "feat: add LiveSummaryPanel view with diff highlighting"
```

---

### Task 5: Integrate LiveSummaryPanel into ContentView

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/ContentView.swift`

- [ ] **Step 1: Replace the transcript section with an HSplitView**

In `ContentView`'s `rootContent` computed property, find the transcript section block (lines 197-241):

```swift
            // Collapsible transcript (hidden when live transcript is disabled)
            if controllerState.showLiveTranscript {
                DisclosureGroup(isExpanded: $isTranscriptExpanded) {
                    IsolatedTranscriptWrapper(state: controllerState)
                        .frame(height: 150)
                } label: {
                    ...
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
```

Replace the entire `if controllerState.showLiveTranscript { ... }` block with:

```swift
            // Transcript + optional live summary sidebar
            if controllerState.showLiveTranscript {
                if controllerState.isRunning && settings.showLiveSummaryPanel {
                    HSplitView {
                        transcriptSection(controllerState: controllerState)
                        LiveSummaryPanel(
                            conversationState: controllerState.conversationState,
                            visibleSections: settings.liveSummarySections
                        )
                        .frame(minWidth: 150, idealWidth: 200)
                    }
                    .frame(minHeight: 150)
                } else {
                    transcriptSection(controllerState: controllerState)
                }
            }
```

- [ ] **Step 2: Extract the transcript DisclosureGroup into a helper method**

Add a private method to `ContentView` (after the `rootContent` property, before `bodyWithModifiers`):

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
                if !controllerState.liveTranscript.isEmpty {
                    Text("(\(controllerState.liveTranscript.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isTranscriptExpanded && !controllerState.liveTranscript.isEmpty {
                    Button {
                        openWindow(id: "transcript")
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Open transcript in separate window")

                    Button {
                        copyTranscript()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Copy transcript")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
```

- [ ] **Step 3: Build to verify no compiler errors**

Run:
```bash
cd OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: Build succeeds. The `HSplitView` is a standard SwiftUI component on macOS.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/ContentView.swift
git commit -m "feat: integrate LiveSummaryPanel sidebar into ContentView"
```

---

### Task 6: Manual integration test

**Files:** None (testing only)

- [ ] **Step 1: Build and launch the app**

Run:
```bash
cd OpenOats && swift build -c debug 2>&1 | tail -5
```

Then launch the built app.

- [ ] **Step 2: Verify settings**

Open Settings (`Cmd+,`) → Intelligence tab. Verify:
- "Live Summary" section exists after "Classic Suggestions"
- Master toggle "Show live summary panel during calls" is on by default
- Section checkboxes appear when toggle is on: Topic, Summary, Open Questions, Decisions are checked; Tensions and Their Goals are unchecked
- Toggling the master off hides the section checkboxes
- Toggling sections on/off persists after closing and reopening Settings

- [ ] **Step 3: Verify live session layout**

Start a live session (click Idle → Live). Verify:
- The window splits into transcript (left) and summary panel (right)
- The summary panel shows section headers with "None yet" / "Waiting for conversation..." placeholders
- The divider between panes is draggable
- Speak into the mic to generate transcript content
- After several utterances, the summary panel should update with conversation state from the LLM
- Updated sections should briefly highlight with accent color, then fade

- [ ] **Step 4: Verify panel toggle**

In Settings, turn off "Show live summary panel during calls". Verify:
- The summary panel disappears and transcript takes full width
- Turning it back on restores the split layout

- [ ] **Step 5: Verify session end behavior**

Stop the session. Verify:
- The layout returns to single-column (no summary panel visible)

- [ ] **Step 6: Commit any fixes if needed**

If any issues were found and fixed during testing:
```bash
git add -A
git commit -m "fix: address issues found during live summary panel testing"
```
