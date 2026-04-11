# Accumulating Live Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `ConversationState`-mirroring live summary with a new `LiveSummaryEngine` that produces an accumulating summary + key points via periodic LLM calls using only the delta since the last update.

**Architecture:** New `@Observable @MainActor` engine class holds internal state (summary text, key points list, utterance buffer). Every 6 utterances it fires an LLM call with the previous summary plus the buffered utterances. Results are pulled into `LiveSessionState` on each polling tick and rendered in a rewritten `LiveSummaryPanel`.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 15+, `@Observable` pattern, `OpenRouterClient` for LLM calls.

---

## File Structure

| File | Responsibility |
|------|---------------|
| **New:** `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift` | Accumulating summary engine: utterance buffer, LLM call, state |
| `OpenOats/Sources/OpenOats/App/AppLaunchContext.swift` | Add `liveSummaryEngine` to `AppServices` struct |
| `OpenOats/Sources/OpenOats/App/AppContainer.swift` | Instantiate `LiveSummaryEngine` in `makeServices` and wire it via `setViewServices` |
| `OpenOats/Sources/OpenOats/App/AppCoordinator.swift` | Add `_liveSummaryEngine` backing store, accessor, and `setViewServices` parameter |
| `OpenOats/Sources/OpenOats/App/LiveSessionController.swift` | Call `liveSummaryEngine?.onUtterance` in `handleNewUtterance`. Call `.clear()` on session start. Expose engine state on `LiveSessionState`. Remove `conversationState` plumbing. |
| **Rewrite:** `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` | New inputs (`summary`, `keyPoints`, `isGenerating`), two-section layout, larger text, simplified diff highlighting |
| `OpenOats/Sources/OpenOats/Views/ContentView.swift` | Pass new props to panel. Remove `maxWidth: 280`. Bump `minWidth`/`idealWidth`. |
| `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift` | Remove `liveSummarySections` property (keep `showLiveSummaryPanel`) |
| `OpenOats/Sources/OpenOats/Views/SettingsView.swift` | Remove per-section toggles and `liveSummarySectionToggle` helper (keep master toggle) |

---

### Task 1: Create LiveSummaryEngine

**Files:**
- Create: `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift`

- [ ] **Step 1: Create the engine file**

Create `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift` with:

```swift
import Foundation
import Observation

/// Builds an accumulating meeting summary + key points list via periodic LLM calls.
/// Independent of the suggestion pipeline — runs regardless of sidebar mode.
@Observable
@MainActor
final class LiveSummaryEngine {
    // MARK: - Observable State

    @ObservationIgnored nonisolated(unsafe) private var _accumulatedSummary: String = ""
    private(set) var accumulatedSummary: String {
        get { access(keyPath: \.accumulatedSummary); return _accumulatedSummary }
        set { withMutation(keyPath: \.accumulatedSummary) { _accumulatedSummary = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _keyPoints: [String] = []
    private(set) var keyPoints: [String] {
        get { access(keyPath: \.keyPoints); return _keyPoints }
        set { withMutation(keyPath: \.keyPoints) { _keyPoints = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isGenerating: Bool = false
    private(set) var isGenerating: Bool {
        get { access(keyPath: \.isGenerating); return _isGenerating }
        set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
    }

    // MARK: - Internal State

    private var utteranceBuffer: [Utterance] = []
    private var lastProcessedUtteranceID: Utterance.ID?
    private var updateTask: Task<Void, Never>?

    private let settings: AppSettings
    private let client = OpenRouterClient()

    /// Update fires when the buffer reaches this many utterances.
    private let updateThresholdUtterances = 6

    // MARK: - Init

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    func onUtterance(_ utterance: Utterance) {
        guard utterance.id != lastProcessedUtteranceID else { return }
        lastProcessedUtteranceID = utterance.id

        utteranceBuffer.append(utterance)

        guard utteranceBuffer.count >= updateThresholdUtterances else { return }
        guard updateTask == nil else { return }
        guard hasValidCredentials else { return }

        let bufferSnapshot = utteranceBuffer
        utteranceBuffer.removeAll()

        isGenerating = true
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isGenerating = false
                    self.updateTask = nil
                }
            }
            await self.performUpdate(newUtterances: bufferSnapshot)
        }
    }

    func clear() {
        updateTask?.cancel()
        updateTask = nil
        accumulatedSummary = ""
        keyPoints = []
        utteranceBuffer.removeAll()
        lastProcessedUtteranceID = nil
        isGenerating = false
    }

    // MARK: - Update

    private func performUpdate(newUtterances: [Utterance]) async {
        let previousSummary = accumulatedSummary
        let prompt = buildPrompt(previousSummary: previousSummary, newUtterances: newUtterances)

        do {
            let response = try await client.complete(
                apiKey: llmApiKey,
                model: activePrimaryModel,
                messages: prompt,
                maxTokens: 2048,
                baseURL: llmBaseURL
            )
            let jsonString = extractJSON(from: response)
            guard let data = jsonString.data(using: .utf8) else { return }
            let update = try JSONDecoder().decode(SummaryUpdate.self, from: data)

            accumulatedSummary = update.summary
            appendDedupedKeyPoints(update.newKeyPoints)
        } catch {
            print("[LiveSummaryEngine] Update failed: \(error)")
        }
    }

    private func appendDedupedKeyPoints(_ incoming: [String]) {
        let existing = Set(keyPoints.map { $0.lowercased() })
        var merged = keyPoints
        for point in incoming {
            let trimmed = point.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !existing.contains(trimmed.lowercased()) {
                merged.append(trimmed)
            }
        }
        keyPoints = merged
    }

    // MARK: - Prompt

    private struct SummaryUpdate: Codable {
        let summary: String
        let newKeyPoints: [String]
    }

    private func buildPrompt(previousSummary: String, newUtterances: [Utterance]) -> [OpenRouterClient.Message] {
        let system = """
        You are a live meeting notetaker. You will be given the current running summary \
        of a meeting and a batch of new utterances. Produce an UPDATED summary that \
        incorporates the new material.

        Rules:
        - Do not remove information from the previous summary.
        - You MAY condense or tighten earlier sections to keep the summary readable.
        - Append newly-discussed topics to the appropriate place in the summary.
        - Write in past tense, as if taking notes after the fact.
        - The summary should grow as the meeting progresses.

        Also produce a list of NEW key points from the new utterances only. Do not \
        repeat key points that were already captured earlier. Each key point is a \
        short, self-contained bullet.

        Respond ONLY with valid JSON matching this schema:
        {
          "summary": "...",
          "newKeyPoints": ["...", "..."]
        }
        """

        var utteranceText = ""
        for u in newUtterances {
            let speakerLabel = u.speaker.isRemote ? "Them" : "You"
            utteranceText += "\(speakerLabel): \(u.displayText)\n"
        }

        let user = """
        PREVIOUS SUMMARY:
        \(previousSummary.isEmpty ? "(none yet)" : previousSummary)

        NEW UTTERANCES:
        \(utteranceText)
        Produce the updated summary and new key points.
        """

        return [
            OpenRouterClient.Message(role: "system", content: system),
            OpenRouterClient.Message(role: "user", content: user),
        ]
    }

    // MARK: - LLM Helpers

    private var hasValidCredentials: Bool {
        switch settings.llmProvider {
        case .openRouter:
            return !settings.openRouterApiKey.isEmpty
        case .ollama, .mlx, .openAICompatible:
            return llmBaseURL != nil
        }
    }

    private var activePrimaryModel: String {
        switch settings.llmProvider {
        case .openRouter: settings.selectedModel
        case .ollama: settings.ollamaLLMModel
        case .mlx: settings.mlxModel
        case .openAICompatible: settings.openAILLMModel
        }
    }

    private var llmApiKey: String? {
        switch settings.llmProvider {
        case .openRouter: settings.openRouterApiKey
        case .ollama: nil
        case .mlx: nil
        case .openAICompatible:
            settings.openAILLMApiKey.isEmpty ? nil : settings.openAILLMApiKey
        }
    }

    private var llmBaseURL: URL? {
        switch settings.llmProvider {
        case .openRouter: return nil
        case .ollama:
            return OpenRouterClient.chatCompletionsURL(from: settings.ollamaBaseURL)
        case .mlx:
            return OpenRouterClient.chatCompletionsURL(from: settings.mlxBaseURL)
        case .openAICompatible:
            return OpenRouterClient.chatCompletionsURL(from: settings.openAILLMBaseURL)
        }
    }

    private func extractJSON(from text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") { s = String(s.dropFirst(7)) }
        else if s.hasPrefix("```") { s = String(s.dropFirst(3)) }
        if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -10
```

Expected: Build succeeds. If it fails because of the `AppSettings` reference or `OpenRouterClient.Message`, those types are already defined in the codebase — verify the imports match other engine files.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift
git commit -m "feat: add LiveSummaryEngine for accumulating meeting summaries"
```

---

### Task 2: Wire engine into AppServices and AppContainer

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/AppLaunchContext.swift`
- Modify: `OpenOats/Sources/OpenOats/App/AppContainer.swift`

- [ ] **Step 1: Add field to AppServices struct**

In `AppLaunchContext.swift` around line 15, add a new field to the `AppServices` struct:

```swift
struct AppServices {
    let knowledgeBase: KnowledgeBase
    let suggestionEngine: SuggestionEngine
    let sidecastEngine: SidecastEngine
    let liveSummaryEngine: LiveSummaryEngine
    let transcriptionEngine: TranscriptionEngine
    let liveTranscriptCleaner: LiveTranscriptCleaner
    let audioRecorder: AudioRecorder
    let batchAudioTranscriber: BatchAudioTranscriber
}
```

- [ ] **Step 2: Instantiate engine in makeServices**

In `AppContainer.swift`, in the `makeServices(settings:coordinator:)` method around line 128, after the `sidecastEngine` instantiation (around line 135-139), add:

```swift
        let liveSummaryEngine = LiveSummaryEngine(settings: settings)
```

- [ ] **Step 3: Pass engine through AppServices return**

In the same `makeServices` method around line 156, add the new field to the returned `AppServices`:

```swift
        return AppServices(
            knowledgeBase: knowledgeBase,
            suggestionEngine: suggestionEngine,
            sidecastEngine: sidecastEngine,
            liveSummaryEngine: liveSummaryEngine,
            transcriptionEngine: transcriptionEngine,
            liveTranscriptCleaner: LiveTranscriptCleaner(
                settings: settings,
                transcriptStore: coordinator.transcriptStore
            ),
            audioRecorder: AudioRecorder(outputDirectory: notesDirectory),
            batchAudioTranscriber: BatchAudioTranscriber()
        )
```

- [ ] **Step 4: Pass engine into setViewServices**

In the same file, in `ensureServicesInitialized(settings:coordinator:)` method around line 179, update the `setViewServices` call to include the new engine:

```swift
        coordinator.setViewServices(
            knowledgeBase: services.knowledgeBase,
            suggestionEngine: services.suggestionEngine,
            sidecastEngine: services.sidecastEngine,
            liveSummaryEngine: services.liveSummaryEngine
        )
```

Note: `setViewServices` is updated in Task 3 to accept this new parameter.

- [ ] **Step 5: Commit (will not build yet — intentional)**

```bash
git add OpenOats/Sources/OpenOats/App/AppLaunchContext.swift OpenOats/Sources/OpenOats/App/AppContainer.swift
git commit -m "feat: wire LiveSummaryEngine through AppServices and AppContainer"
```

We'll build after Task 3 when `AppCoordinator.setViewServices` has the new parameter.

---

### Task 3: Add engine accessor to AppCoordinator

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/AppCoordinator.swift`

- [ ] **Step 1: Add backing store and accessor**

In `AppCoordinator.swift`, after the `_sidecastEngine` block (around line 108-111), add:

```swift
    @ObservationIgnored nonisolated(unsafe) private var _liveSummaryEngine: LiveSummaryEngine?
    nonisolated var liveSummaryEngine: LiveSummaryEngine? {
        get { _liveSummaryEngine }
    }
```

- [ ] **Step 2: Update setViewServices signature and body**

In the same file, update `setViewServices` (around line 113-121) to accept and assign the new engine:

```swift
    func setViewServices(
        knowledgeBase: KnowledgeBase,
        suggestionEngine: SuggestionEngine,
        sidecastEngine: SidecastEngine,
        liveSummaryEngine: LiveSummaryEngine
    ) {
        _knowledgeBase = knowledgeBase
        _suggestionEngine = suggestionEngine
        _sidecastEngine = sidecastEngine
        _liveSummaryEngine = liveSummaryEngine
    }
```

- [ ] **Step 3: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -10
```

Expected: Build succeeds. Tasks 1, 2, and 3 should all compile cleanly together now.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/AppCoordinator.swift
git commit -m "feat: expose liveSummaryEngine on AppCoordinator"
```

---

### Task 4: Wire engine into LiveSessionController

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`

- [ ] **Step 1: Replace conversationState on LiveSessionState**

In `LiveSessionController.swift`, find the `LiveSessionState` class (lines 9-36). Remove the `conversationState` property (line 35) and add three new properties after `scratchpadText`:

```swift
    /// The user's live scratchpad text for the active session.
    var scratchpadText: String = ""
    var liveSummary: String = ""
    var liveKeyPoints: [String] = []
    var liveSummaryIsGenerating: Bool = false
}
```

The line `var conversationState: ConversationState = .empty` should be deleted.

- [ ] **Step 2: Add clear() call in startSession**

In the `startSession(settings:)` method around line 126, add a `clear()` call after the existing `sidecastEngine` clear:

```swift
    func startSession(settings: AppSettings) {
        coordinator.suggestionEngine?.clear()
        coordinator.sidecastEngine?.clear()
        coordinator.liveSummaryEngine?.clear()
        let calEvent = settings.calendarIntegrationEnabled
            ? container.calendarManager?.currentEvent()
            : nil
        let metadata = MeetingMetadata.manual(calendarEvent: calEvent)
        coordinator.handle(.userStarted(metadata), settings: settings)
    }
```

- [ ] **Step 3: Call onUtterance in handleNewUtterance**

In `handleNewUtterance(_:settings:)` around lines 212-229, after the existing `switch settings.sidebarMode` block that routes to `suggestionEngine` or `sidecastEngine`, add an unconditional call to the live summary engine:

Find this block:
```swift
        // Trigger the active realtime assistant from either speaker
        switch settings.sidebarMode {
        case .classicSuggestions:
            coordinator.suggestionEngine?.onUtterance(last)
        case .sidecast:
            coordinator.sidecastEngine?.onUtterance(last)
        }
```

And change it to:
```swift
        // Trigger the active realtime assistant from either speaker
        switch settings.sidebarMode {
        case .classicSuggestions:
            coordinator.suggestionEngine?.onUtterance(last)
        case .sidecast:
            coordinator.sidecastEngine?.onUtterance(last)
        }

        // Live summary runs independently of sidebar mode
        coordinator.liveSummaryEngine?.onUtterance(last)
```

- [ ] **Step 4: Update refreshState to copy engine state**

In `refreshState(settings:)` around lines 572-579, find the block that copies `conversationState`:

```swift
        let nextConversationState = coordinator.transcriptStore.conversationState
        if state.conversationState.lastUpdatedAt != nextConversationState.lastUpdatedAt {
            state.conversationState = nextConversationState
        }
```

Replace it with:

```swift
        let summaryEngine = coordinator.liveSummaryEngine
        set(\.liveSummary, summaryEngine?.accumulatedSummary ?? "")
        set(\.liveSummaryIsGenerating, summaryEngine?.isGenerating ?? false)
        let nextKeyPoints = summaryEngine?.keyPoints ?? []
        if state.liveKeyPoints != nextKeyPoints {
            state.liveKeyPoints = nextKeyPoints
        }
```

- [ ] **Step 5: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -15
```

Expected: Build fails with errors in `LiveSummaryPanel.swift` and `ContentView.swift` because those still reference the removed `conversationState` field. That's expected — we'll fix them in Tasks 5 and 6.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/LiveSessionController.swift
git commit -m "feat: wire LiveSummaryEngine through LiveSessionController"
```

---

### Task 5: Rewrite LiveSummaryPanel view

**Files:**
- Modify (full rewrite): `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift`

- [ ] **Step 1: Replace the entire file contents**

Replace the full contents of `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` with:

```swift
import SwiftUI

struct LiveSummaryPanel: View {
    let summary: String
    let keyPoints: [String]
    let isGenerating: Bool

    @State private var previousSummary: String = ""
    @State private var previousKeyPoints: [String] = []
    @State private var highlightSummary: Bool = false
    @State private var highlightedKeyPoints: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if summary.isEmpty && keyPoints.isEmpty {
                    emptyState
                } else {
                    if !summary.isEmpty {
                        summarySection
                    }
                    if !keyPoints.isEmpty {
                        keyPointsSection
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: summary) { _, newValue in
            if newValue != previousSummary && !previousSummary.isEmpty {
                triggerSummaryHighlight()
            }
            previousSummary = newValue
        }
        .onChange(of: keyPoints) { _, newValue in
            triggerKeyPointHighlights(newItems: newValue, oldItems: previousKeyPoints)
            previousKeyPoints = newValue
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(isGenerating ? "Generating first summary..." : "Listening...")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 24)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Meeting Summary")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
                Spacer()
            }
            Text(summary)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightSummary ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var keyPointsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Key Points")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(keyPoints, id: \.self) { point in
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(point)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(highlightedKeyPoints.contains(point) ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Diff Highlighting

    private func triggerSummaryHighlight() {
        withAnimation(.easeIn(duration: 0.2)) {
            highlightSummary = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) {
                highlightSummary = false
            }
        }
    }

    private func triggerKeyPointHighlights(newItems: [String], oldItems: [String]) {
        let oldSet = Set(oldItems)
        let newlyAdded = newItems.filter { !oldSet.contains($0) }
        guard !newlyAdded.isEmpty else { return }

        withAnimation(.easeIn(duration: 0.2)) {
            highlightedKeyPoints.formUnion(newlyAdded)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) {
                highlightedKeyPoints.subtract(newlyAdded)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -15
```

Expected: Build still fails because `ContentView.swift` passes the old params to `LiveSummaryPanel`. That's fixed in Task 6.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift
git commit -m "feat: rewrite LiveSummaryPanel for accumulating summary + key points"
```

---

### Task 6: Update ContentView to pass new props and remove maxWidth

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/ContentView.swift`

- [ ] **Step 1: Update the HSplitView block**

In `ContentView.swift`, find the `HSplitView` block inside `rootContent` (around lines 200-209). It currently looks like:

```swift
                    HSplitView {
                        transcriptSection(controllerState: controllerState)
                            .frame(minWidth: 150)
                        LiveSummaryPanel(
                            conversationState: controllerState.conversationState,
                            visibleSections: settings.liveSummarySections
                        )
                        .frame(minWidth: 150, idealWidth: 200, maxWidth: 280)
                    }
                    .frame(minHeight: 150)
```

Replace it with:

```swift
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
```

Changes: new parameter names (`summary`, `keyPoints`, `isGenerating`), removed `maxWidth: 280`, bumped transcript `minWidth` to 200 and summary `minWidth`/`idealWidth` to 200/280.

- [ ] **Step 2: Build to verify**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -15
```

Expected: Build still fails with errors about `liveSummarySections` in SettingsStore/SettingsView. That's fixed in Task 7.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/ContentView.swift
git commit -m "feat: pass new engine state to LiveSummaryPanel, remove maxWidth cap"
```

---

### Task 7: Remove liveSummarySections from settings

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`
- Modify: `OpenOats/Sources/OpenOats/Views/SettingsView.swift`

- [ ] **Step 1: Remove the `liveSummarySections` property from SettingsStore**

In `SettingsStore.swift`, find and delete the entire `_liveSummarySections` backing store and `liveSummarySections` computed property block (added in the previous feature, around lines 299-309). The block looks like:

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

Delete it entirely.

- [ ] **Step 2: Remove the init block for `liveSummarySections`**

In the same file, find and delete the init block (around lines 887-892) that looks like:

```swift
        if let sectionsData = defaults.data(forKey: "liveSummarySections"),
           let decoded = try? JSONDecoder().decode([String].self, from: sectionsData) {
            self._liveSummarySections = Set(decoded)
        } else {
            self._liveSummarySections = ["topic", "summary", "openQuestions", "recentDecisions"]
        }
```

Delete it entirely. Keep the `showLiveSummaryPanel` init block that precedes it.

- [ ] **Step 3: Remove per-section toggles from SettingsView**

In `SettingsView.swift`, find the `Section("Live Summary")` block inside `IntelligenceSettingsTab` (around lines 589-607). It currently looks like:

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

Replace it with:

```swift
                Section("Live Summary") {
                    Toggle("Show live summary panel during calls", isOn: $settings.showLiveSummaryPanel)
                        .font(.system(size: 12))
                    Text("Displays an accumulating summary of the conversation alongside the transcript. Updates every few utterances. Requires an LLM provider.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

- [ ] **Step 4: Remove the `liveSummarySectionToggle` helper**

In the same file, find the `liveSummarySectionToggle(_:key:)` private helper inside `IntelligenceSettingsTab` (added in the previous feature). It looks like:

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

Delete it entirely.

- [ ] **Step 5: Build to verify everything compiles**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -15
```

Expected: `Build complete!` with no errors. If there are lingering references to `liveSummarySections`, grep for them and remove:
```bash
cd /Users/jja/Projects/active/openoats && grep -rn "liveSummarySections" OpenOats/Sources/
```

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift OpenOats/Sources/OpenOats/Views/SettingsView.swift
git commit -m "refactor: remove liveSummarySections (no longer needed)"
```

---

### Task 8: Manual integration test

**Files:** None (testing only)

- [ ] **Step 1: Full build**

Run:
```bash
cd /Users/jja/Projects/active/openoats/OpenOats && swift build -c debug 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 2: Launch from command line to catch logs**

Run:
```bash
/Users/jja/Projects/active/openoats/OpenOats/.build/debug/OpenOats
```

Keep the terminal visible so you can see `[LiveSummaryEngine]` logs.

- [ ] **Step 3: Verify settings**

Open Settings (`Cmd+,`) → Intelligence. Verify:
- "Live Summary" section exists with just one toggle (no per-section checkboxes)
- Toggle is on by default
- Help text mentions "accumulating summary"

- [ ] **Step 4: Verify empty state**

Start a live session (Idle → Live). Verify:
- Window splits into transcript (left) + summary panel (right)
- Summary panel shows "Listening..." placeholder

- [ ] **Step 5: Verify first update fires**

Have a conversation with 6+ utterances (from either speaker). Verify:
- Summary panel shows a subtle spinner near "Meeting Summary" header while generating
- After ~3-10 seconds, summary text appears
- Key points section appears below with at least one bullet
- Check terminal for `[LiveSummaryEngine]` logs — should see no errors

- [ ] **Step 6: Verify accumulation**

Continue talking for another 6+ utterances. Verify:
- On next update, the summary gets longer (not replaced)
- New key points are appended to the list
- The summary section briefly highlights with accent color when updated
- New key points briefly highlight individually

- [ ] **Step 7: Verify session lifecycle**

Stop the session. Start a new one. Verify:
- Panel resets to "Listening..." (previous summary cleared)
- No stale content from previous session

- [ ] **Step 8: Verify max width is gone**

Drag the HSplitView divider to make the summary panel much wider than 280px. Verify:
- The panel expands freely without the 280px cap
- Transcript still has a minimum width (can't collapse to zero)

- [ ] **Step 9: Verify toggle off**

In Settings, turn off "Show live summary panel during calls". Verify:
- Panel disappears during live session
- Transcript takes full width
- Turning it back on restores the split layout

- [ ] **Step 10: Commit any fixes found during testing**

If any issues surfaced:
```bash
git add -A
git commit -m "fix: address issues found during accumulating summary testing"
```
