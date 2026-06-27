# Live Notes Pane — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the live Suggestions pane be switched to a periodically-regenerated "Live Notes" view (the end-of-meeting `NotesEngine` template output over the transcript-so-far) or turned off.

**Architecture:** A new `livePaneMode` setting (Suggestions / Live Notes / Off) gates the third stacked pane. When Live Notes, a new `LiveNotesEngine` reruns its own `NotesEngine` on a ~30s loop over the live transcript (skips silences, never overlaps); when not Suggestions, the suggestion pipeline is never invoked. The regeneration decision is a pure, unit-tested function.

**Tech Stack:** Swift 6.2, SwiftUI, XCTest, Swift Package Manager (`OpenOats/`).

## Global Constraints

- Swift 6.2 / macOS 15+. Build/test from `OpenOats/`: `cd OpenOats && swift build`, `swift test [--filter X]`.
- Tests use `XCTest` with `@testable import OpenOatsKit`.
- `livePaneMode` default `.suggestions` → today's behavior unchanged (incl. `sidebarMode` classic/sidecast).
- When `livePaneMode != .suggestions`, neither `SuggestionEngine` nor `SidecastEngine` `onUtterance` is called.
- Live Notes cadence: full regen every `liveNotesIntervalSeconds` (default 30), only when the transcript gained utterances since the last run, never overlapping a run in flight, and only past a minimum floor of 4 utterances.
- The live `NotesEngine` instance is SEPARATE from the post-meeting one (`coordinator.notesEngine`) — never touch the Generate Notes flow or the Summary pane.
- Reuse the session's template (resolved from `coordinator.sessionTemplateSnapshot?.id` via `templateStore.template(for:)`, fallback `TemplateStore.genericID`), mirroring `NotesController.generateNotes`.
- Line numbers are approximate; locate anchors by matching quoted text.
- Commit messages: plain `feat:`/`test:` subjects (repo tooling appends trailers).

---

### Task 1: Settings — LivePaneMode + interval

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsTypes.swift`
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`
- Test: `OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift`

**Interfaces:**
- Produces: `enum LivePaneMode: String, CaseIterable, Identifiable { case suggestions, liveNotes, off }` with `displayName`; `AppSettings.livePaneMode: LivePaneMode` (default `.suggestions`, key `"livePaneMode"`); `AppSettings.liveNotesIntervalSeconds: Int` (default `30`, key `"liveNotesIntervalSeconds"`).

- [ ] **Step 1: Write the failing test**

In `AppSettingsTests.swift`, add (reuse the existing `makeSettings()` helper):

```swift
    // MARK: - Live Pane Settings

    func testLivePaneDefaults() {
        let settings = makeSettings()
        XCTAssertEqual(settings.livePaneMode, .suggestions)
        XCTAssertEqual(settings.liveNotesIntervalSeconds, 30)
    }

    func testLivePanePersists() {
        let settings = makeSettings()
        settings.livePaneMode = .liveNotes
        settings.liveNotesIntervalSeconds = 45
        XCTAssertEqual(settings.livePaneMode, .liveNotes)
        XCTAssertEqual(settings.liveNotesIntervalSeconds, 45)
    }

    func testLivePaneModeAllCases() {
        XCTAssertEqual(LivePaneMode.allCases, [.suggestions, .liveNotes, .off])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter AppSettingsTests 2>&1 | tail -10`
Expected: FAIL — `cannot find type 'LivePaneMode'` / no member `livePaneMode`.

- [ ] **Step 3: Add the enum** (`SettingsTypes.swift`)

Immediately after the `SidebarMode` enum (the block ending with its `description` computed property and closing `}`), add:

```swift
enum LivePaneMode: String, CaseIterable, Identifiable {
    case suggestions
    case liveNotes
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .suggestions: "Suggestions"
        case .liveNotes: "Live Notes"
        case .off: "Off"
        }
    }
}
```

- [ ] **Step 4: Add the settings accessors** (`SettingsStore.swift`)

Immediately after the `sidebarMode` computed property's closing brace, add:

```swift
    @ObservationIgnored nonisolated(unsafe) private var _livePaneMode: LivePaneMode
    var livePaneMode: LivePaneMode {
        get { access(keyPath: \.livePaneMode); return _livePaneMode }
        set {
            withMutation(keyPath: \.livePaneMode) {
                _livePaneMode = newValue
                defaults.set(newValue.rawValue, forKey: "livePaneMode")
            }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var _liveNotesIntervalSeconds: Int
    var liveNotesIntervalSeconds: Int {
        get { access(keyPath: \.liveNotesIntervalSeconds); return _liveNotesIntervalSeconds }
        set {
            withMutation(keyPath: \.liveNotesIntervalSeconds) {
                _liveNotesIntervalSeconds = newValue
                defaults.set(newValue, forKey: "liveNotesIntervalSeconds")
            }
        }
    }
```

- [ ] **Step 5: Initialize the stored values** (`SettingsStore.swift`, in `init(storage:)`)

After the line `self._sidebarMode = SidebarMode(rawValue: defaults.string(forKey: "sidebarMode") ?? "") ?? .classicSuggestions`, add:

```swift
        self._livePaneMode = LivePaneMode(rawValue: defaults.string(forKey: "livePaneMode") ?? "") ?? .suggestions
        let storedInterval = defaults.integer(forKey: "liveNotesIntervalSeconds")
        self._liveNotesIntervalSeconds = storedInterval == 0 ? 30 : storedInterval
```

(`integer(forKey:)` returns 0 when unset, so map 0 → the 30 default.)

- [ ] **Step 6: Run tests and build**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter AppSettingsTests 2>&1 | tail -10`
Expected: build succeeds; new + existing AppSettings tests pass.

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsTypes.swift \
        OpenOats/Sources/OpenOats/Settings/SettingsStore.swift \
        OpenOats/Tests/OpenOatsTests/AppSettingsTests.swift
git commit -m "feat: add livePaneMode + live notes interval settings"
```

---

### Task 2: LiveNotesEngine pure core (scheduler + transcript adapter)

**Files:**
- Create: `OpenOats/Sources/OpenOats/Intelligence/LiveNotesEngine.swift`
- Test: `OpenOats/Tests/OpenOatsTests/LiveNotesEngineCoreTests.swift`

**Interfaces:**
- Produces: `enum LiveNotesScheduler { static func shouldRegenerate(currentCount: Int, lastGeneratedCount: Int, minUtterances: Int, isGenerating: Bool) -> Bool }`; `LiveNotesEngine.records(from: [Utterance]) -> [SessionRecord]` (static).

- [ ] **Step 1: Write the failing test**

Create `OpenOats/Tests/OpenOatsTests/LiveNotesEngineCoreTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

final class LiveNotesEngineCoreTests: XCTestCase {

    func testNoRegenWhileGenerating() {
        XCTAssertFalse(LiveNotesScheduler.shouldRegenerate(
            currentCount: 10, lastGeneratedCount: 2, minUtterances: 4, isGenerating: true))
    }

    func testNoRegenBelowFloor() {
        XCTAssertFalse(LiveNotesScheduler.shouldRegenerate(
            currentCount: 3, lastGeneratedCount: 0, minUtterances: 4, isGenerating: false))
    }

    func testNoRegenWithoutNewContent() {
        XCTAssertFalse(LiveNotesScheduler.shouldRegenerate(
            currentCount: 8, lastGeneratedCount: 8, minUtterances: 4, isGenerating: false))
    }

    func testRegenWhenNewContentPastFloorAndIdle() {
        XCTAssertTrue(LiveNotesScheduler.shouldRegenerate(
            currentCount: 9, lastGeneratedCount: 8, minUtterances: 4, isGenerating: false))
    }

    func testRecordsAdapterMapsFields() {
        let u = Utterance(id: UUID(), text: "hello", speaker: .local,
                          timestamp: Date(timeIntervalSince1970: 100),
                          cleanedText: "Hello.", cleanupStatus: nil)
        let records = LiveNotesEngine.records(from: [u])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].text, "hello")
        XCTAssertEqual(records[0].cleanedText, "Hello.")
        XCTAssertEqual(records[0].timestamp, Date(timeIntervalSince1970: 100))
    }
}
```

(Note: confirm the `Utterance` initializer parameter labels by reading `Domain/Utterance.swift`; `Speaker.local` is the "You" speaker. Adjust the test's `Utterance(...)` call to match the real initializer if the synthesized member-wise init differs — the fields are `id, text, speaker, timestamp, cleanedText, cleanupStatus`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd OpenOats && swift test --filter LiveNotesEngineCoreTests 2>&1 | tail -10`
Expected: FAIL — `cannot find 'LiveNotesScheduler'` / `LiveNotesEngine`.

- [ ] **Step 3: Create the file with the pure core**

Create `OpenOats/Sources/OpenOats/Intelligence/LiveNotesEngine.swift`:

```swift
import Foundation

/// Pure decision for whether the live-notes loop should regenerate this tick.
enum LiveNotesScheduler {
    /// Regenerate only when idle, past the minimum floor, and the transcript grew.
    static func shouldRegenerate(currentCount: Int, lastGeneratedCount: Int,
                                 minUtterances: Int, isGenerating: Bool) -> Bool {
        guard !isGenerating else { return false }
        guard currentCount >= minUtterances else { return false }
        return currentCount > lastGeneratedCount
    }
}

@MainActor
@Observable
final class LiveNotesEngine {
    /// Adapt live utterances to the SessionRecord form NotesEngine consumes.
    static func records(from utterances: [Utterance]) -> [SessionRecord] {
        utterances.map {
            SessionRecord(speaker: $0.speaker, text: $0.text,
                          timestamp: $0.timestamp, cleanedText: $0.cleanedText)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd OpenOats && swift test --filter LiveNotesEngineCoreTests 2>&1 | tail -10`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/LiveNotesEngine.swift \
        OpenOats/Tests/OpenOatsTests/LiveNotesEngineCoreTests.swift
git commit -m "feat: add LiveNotesEngine scheduler + transcript adapter"
```

---

### Task 3: LiveNotesEngine — periodic generation loop

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/LiveNotesEngine.swift`

**Interfaces:**
- Consumes: `NotesEngine.generate(transcript:template:settings:calendarEvent:scratchpad:customGuidance:onFinished:)` (streams to `generatedMarkdown`, sets `isGenerating`), `LiveNotesScheduler.shouldRegenerate(...)`, `LiveNotesEngine.records(from:)`, `AppSettings.liveNotesIntervalSeconds`.
- Produces: `LiveNotesEngine.init(settings: AppSettings)`; `markdown: String`; `isGenerating: Bool`; `lastUpdatedAt: Date?`; `func start(transcriptProvider: @escaping () -> [SessionRecord], templateProvider: @escaping () -> MeetingTemplate, calendarEventProvider: @escaping () -> CalendarEvent?)`; `func clear()`.

- [ ] **Step 1: Add the engine body**

In `LiveNotesEngine.swift`, add the stored state, init, and methods INSIDE the `final class LiveNotesEngine` (keep the existing `static func records`):

```swift
    private(set) var markdown: String = ""
    private(set) var isGenerating: Bool = false
    private(set) var lastUpdatedAt: Date?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let notes = NotesEngine()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var lastGeneratedCount = 0
    @ObservationIgnored private let minUtterances = 4

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Start the periodic regeneration loop. Providers are read fresh each tick,
    /// so template/calendar/transcript timing is handled lazily.
    func start(
        transcriptProvider: @escaping () -> [SessionRecord],
        templateProvider: @escaping () -> MeetingTemplate,
        calendarEventProvider: @escaping () -> CalendarEvent?
    ) {
        loopTask?.cancel()
        markdown = ""
        isGenerating = false
        lastUpdatedAt = nil
        lastGeneratedCount = 0

        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = max(5, self.settings.liveNotesIntervalSeconds)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }

                let records = transcriptProvider()
                guard LiveNotesScheduler.shouldRegenerate(
                    currentCount: records.count,
                    lastGeneratedCount: self.lastGeneratedCount,
                    minUtterances: self.minUtterances,
                    isGenerating: self.isGenerating
                ) else { continue }

                self.lastGeneratedCount = records.count
                await self.regenerate(
                    records: records,
                    template: templateProvider(),
                    calendarEvent: calendarEventProvider()
                )
            }
        }
    }

    func clear() {
        loopTask?.cancel()
        loopTask = nil
        markdown = ""
        isGenerating = false
        lastUpdatedAt = nil
        lastGeneratedCount = 0
    }

    private func regenerate(records: [SessionRecord], template: MeetingTemplate,
                            calendarEvent: CalendarEvent?) async {
        isGenerating = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            notes.generate(
                transcript: records,
                template: template,
                settings: settings,
                calendarEvent: calendarEvent
            ) {
                cont.resume()
            }
        }
        markdown = notes.generatedMarkdown
        isGenerating = false
        lastUpdatedAt = Date()
    }
```

- [ ] **Step 2: Build and confirm core tests still pass**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test --filter LiveNotesEngineCoreTests 2>&1 | tail -5`
Expected: build succeeds; 5 core tests still pass. (The loop + LLM generation are exercised manually in Task 7.)

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/LiveNotesEngine.swift
git commit -m "feat: LiveNotesEngine periodic regeneration loop"
```

---

### Task 4: Wire LiveNotesEngine into the container + coordinator

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/AppLaunchContext.swift` (`AppViewServices` struct, ~line 15)
- Modify: `OpenOats/Sources/OpenOats/App/AppContainer.swift` (`makeViewServices`, ~line 129; `setViewServices` call, ~line 187)
- Modify: `OpenOats/Sources/OpenOats/App/AppCoordinator.swift` (engine property ~line 133; `setViewServices` ~line 161)

**Interfaces:**
- Consumes: `LiveNotesEngine(settings:)` (Task 3)
- Produces: `AppCoordinator.liveNotesEngine: LiveNotesEngine?`

- [ ] **Step 1: Add `liveNotesEngine` to `AppViewServices`** (`AppLaunchContext.swift`)

In the `struct AppViewServices`, add the field (next to `liveSummaryEngine`):

```swift
    let liveNotesEngine: LiveNotesEngine
```

- [ ] **Step 2: Construct it in `makeViewServices`** (`AppContainer.swift`)

After `let liveSummaryEngine = LiveSummaryEngine(settings: settings)`, add:

```swift
        let liveNotesEngine = LiveNotesEngine(settings: settings)
```

And in the `return AppViewServices(...)` initializer, add the argument after `liveSummaryEngine: liveSummaryEngine`:

```swift
            liveNotesEngine: liveNotesEngine
```

- [ ] **Step 3: Add the coordinator property** (`AppCoordinator.swift`)

After the `_liveSummaryEngine` property block (the `nonisolated var liveSummaryEngine` getter, ~line 136), add:

```swift
    @ObservationIgnored nonisolated(unsafe) private var _liveNotesEngine: LiveNotesEngine?
    nonisolated var liveNotesEngine: LiveNotesEngine? {
        get { _liveNotesEngine }
    }
```

- [ ] **Step 4: Accept + store it in `setViewServices`** (`AppCoordinator.swift`)

Change the `setViewServices` signature to add the parameter, and store it. The method becomes:

```swift
    func setViewServices(
        knowledgeBase: KnowledgeBase,
        suggestionEngine: SuggestionEngine,
        sidecastEngine: SidecastEngine,
        liveSummaryEngine: LiveSummaryEngine,
        liveNotesEngine: LiveNotesEngine
    ) {
        _knowledgeBase = knowledgeBase
        _suggestionEngine = suggestionEngine
        _sidecastEngine = sidecastEngine
        _liveSummaryEngine = liveSummaryEngine
        _liveNotesEngine = liveNotesEngine
    }
```

- [ ] **Step 5: Pass it at the call site** (`AppContainer.swift`, the `coordinator.setViewServices(...)` call ~line 187)

Add the argument after `liveSummaryEngine: services.liveSummaryEngine`:

```swift
            liveNotesEngine: services.liveNotesEngine
```

- [ ] **Step 6: Build and run the suite**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: build succeeds; suite passes.

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/AppLaunchContext.swift \
        OpenOats/Sources/OpenOats/App/AppContainer.swift \
        OpenOats/Sources/OpenOats/App/AppCoordinator.swift
git commit -m "feat: wire LiveNotesEngine through container and coordinator"
```

---

### Task 5: Gate the suggestion pipeline + drive/project Live Notes

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`

**Interfaces:**
- Consumes: `AppSettings.livePaneMode`, `AppCoordinator.liveNotesEngine`, `LiveNotesEngine.records(from:)`/`start(...)`/`clear()`, `coordinator.transcriptStore.utterances`, `coordinator.sessionTemplateSnapshot`, `coordinator.templateStore`, `TemplateStore.genericID`.
- Produces: projected state fields `liveNotesMarkdown: String`, `liveNotesIsGenerating: Bool`, `liveNotesUpdatedAt: Date?` on the controller's observable state.

- [ ] **Step 1: Gate the per-utterance dispatch on `livePaneMode`**

Find this block (~line 493):

```swift
        // Trigger the active realtime assistant from either speaker
        switch settings.sidebarMode {
        case .classicSuggestions:
            coordinator.suggestionEngine?.onUtterance(last)
        case .sidecast:
            coordinator.sidecastEngine?.onUtterance(last)
        }
```

Replace it with:

```swift
        // Trigger the active realtime assistant only when the live pane shows Suggestions.
        if settings.livePaneMode == .suggestions {
            switch settings.sidebarMode {
            case .classicSuggestions:
                coordinator.suggestionEngine?.onUtterance(last)
            case .sidecast:
                coordinator.sidecastEngine?.onUtterance(last)
            }
        }
```

(The `coordinator.liveSummaryEngine?.onUtterance(last)` line right below is unchanged.)

- [ ] **Step 2: Add the Live Notes start/stop helper**

Add this private method to `LiveSessionController` (near `startSession`):

```swift
    /// Resolve the session's template the same way the post-meeting notes do.
    private func sessionNotesTemplate() -> MeetingTemplate {
        let id = coordinator.sessionTemplateSnapshot?.id ?? TemplateStore.genericID
        return coordinator.templateStore.template(for: id)
            ?? coordinator.templateStore.template(for: TemplateStore.genericID)
            ?? TemplateStore.builtInTemplates.first!
    }

    /// Start or stop the Live Notes loop based on `livePaneMode`.
    private func updateLiveNotes(settings: AppSettings, calendarEvent: CalendarEvent?) {
        guard let engine = coordinator.liveNotesEngine else { return }
        engine.clear()
        guard settings.livePaneMode == .liveNotes else { return }
        engine.start(
            transcriptProvider: { [weak coordinator] in
                guard let coordinator else { return [] }
                return LiveNotesEngine.records(from: coordinator.transcriptStore.utterances)
            },
            templateProvider: { [weak self] in
                self?.sessionNotesTemplate() ?? TemplateStore.builtInTemplates.first!
            },
            calendarEventProvider: { calendarEvent }
        )
    }
```

- [ ] **Step 2b: Call it at session start and stop**

In `startSession`, immediately after `let metadata = MeetingMetadata.manual(calendarEvent: calEvent)` (~line 318), add:

```swift
        updateLiveNotes(settings: settings, calendarEvent: calEvent)
```

In `stopSession` (the method that begins `func stopSession(settings: AppSettings)`), add as the first line of the body:

```swift
        coordinator.liveNotesEngine?.clear()
```

- [ ] **Step 3: Add projected state fields**

Find the projected-state field `var liveSummaryIsGenerating: Bool = false` (~line 58) and add right after it:

```swift
    var liveNotesMarkdown: String = ""
    var liveNotesIsGenerating: Bool = false
    var liveNotesUpdatedAt: Date? = nil
```

- [ ] **Step 4: Populate them in `syncProjectedState`**

Find where the live-summary state is projected (~line 1288):

```swift
        let summaryEngine = coordinator.liveSummaryEngine
        set(\.liveSummaryIsGenerating, summaryEngine?.isGenerating ?? false)
```

Add right after it:

```swift
        let liveNotes = coordinator.liveNotesEngine
        set(\.liveNotesMarkdown, liveNotes?.markdown ?? "")
        set(\.liveNotesIsGenerating, liveNotes?.isGenerating ?? false)
        set(\.liveNotesUpdatedAt, liveNotes?.lastUpdatedAt)
```

(`set(_:_:)` is the existing change-only setter used for the other projected fields.)

- [ ] **Step 5: Build and run the suite**

Run: `cd OpenOats && swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: build succeeds; suite passes.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/LiveSessionController.swift
git commit -m "feat: gate suggestions and drive Live Notes by livePaneMode"
```

---

### Task 6: Stacked pane switch + LiveNotesPanel view

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/StackedPanesView.swift`
- Create: `OpenOats/Sources/OpenOats/Views/LiveNotesPanel.swift`

**Interfaces:**
- Consumes: `settings.livePaneMode`, `controllerState.liveNotesMarkdown`/`liveNotesIsGenerating`/`liveNotesUpdatedAt` (Task 5), `settings.suggestionsCollapsed`, `settings.suggestionsZoom`.

- [ ] **Step 1: Create the panel view**

Create `OpenOats/Sources/OpenOats/Views/LiveNotesPanel.swift`:

```swift
import SwiftUI

/// Read-only periodically-regenerated meeting notes (template output) shown live.
struct LiveNotesPanel: View {
    let markdown: String
    let isGenerating: Bool
    let updatedAt: Date?
    var zoom: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusRow
            if markdown.isEmpty {
                Text(isGenerating ? "Generating notes…" : "Notes will appear here as the meeting progresses.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LiveNotesMarkdownText(markdown: markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if isGenerating {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let updatedAt {
                Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Updated \(updatedAt.formatted(.relative(presentation: .numeric)))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// Lightweight markdown renderer (headings + bullets + inline emphasis), self-contained
/// so it doesn't depend on NotesDetailView's asset-aware renderer.
private struct LiveNotesMarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                line(String(raw))
            }
        }
    }

    @ViewBuilder
    private func line(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") {
            Text(inline(String(trimmed.dropFirst(4)))).font(.system(size: 12, weight: .semibold))
        } else if trimmed.hasPrefix("## ") {
            Text(inline(String(trimmed.dropFirst(3)))).font(.system(size: 13, weight: .bold))
        } else if trimmed.hasPrefix("# ") {
            Text(inline(String(trimmed.dropFirst(2)))).font(.system(size: 15, weight: .bold))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(.system(size: 12))
                Text(inline(String(trimmed.dropFirst(2)))).font(.system(size: 12))
            }
        } else if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else {
            Text(inline(trimmed)).font(.system(size: 12))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
```

- [ ] **Step 2: Switch the third pane on `livePaneMode`** (`StackedPanesView.swift`)

Find the Suggestions `PaneShell` block (the one with `title: "Suggestions"` containing `InlineSuggestionsView(...)`). Replace the WHOLE `PaneShell(... title: "Suggestions" ...) { InlineSuggestionsView(...) } .frame(...)` block with a switch:

```swift
            switch settings.livePaneMode {
            case .suggestions:
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

            case .liveNotes:
                PaneShell(
                    title: "Live Notes",
                    badge: nil,
                    paneID: .suggestions,
                    isCollapsed: $settings.suggestionsCollapsed,
                    focusedPane: focusedPane
                ) {
                    LiveNotesPanel(
                        markdown: controllerState.liveNotesMarkdown,
                        isGenerating: controllerState.liveNotesIsGenerating,
                        updatedAt: controllerState.liveNotesUpdatedAt,
                        zoom: settings.suggestionsZoom
                    )
                }
                .frame(minHeight: settings.suggestionsCollapsed ? 28 : 80)

            case .off:
                EmptyView()
            }
```

(Reuses the existing `paneID: .suggestions` and `settings.suggestionsCollapsed`/`suggestionsZoom` so the pane keeps its splitter identity. If `controllerState` / `settings` / `focusedPane` are named differently in this view's scope, match the existing Suggestions block's references — copy them verbatim from the block you're replacing.)

- [ ] **Step 3: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/LiveNotesPanel.swift \
        OpenOats/Sources/OpenOats/Views/StackedPanesView.swift
git commit -m "feat: render Live Notes / Suggestions / Off in the third pane"
```

---

### Task 7: Settings UI + end-to-end verification

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/SidecastSettingsTab.swift`

**Interfaces:**
- Consumes: `settings.livePaneMode`, `settings.liveNotesIntervalSeconds`, `settings.sidebarMode`.

- [ ] **Step 1: Add the `livePaneMode` picker + interval**

In `SidecastSettingsTab.swift`, immediately BEFORE the existing `Picker("Mode", selection: $settings.sidebarMode)` (~line 16), add:

```swift
                    Picker("Live pane", selection: $settings.livePaneMode) {
                        ForEach(LivePaneMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if settings.livePaneMode == .liveNotes {
                        Stepper("Refresh every \(settings.liveNotesIntervalSeconds)s",
                                value: $settings.liveNotesIntervalSeconds, in: 10...120, step: 5)
                            .font(.system(size: 12))
                        Text("Re-generates the full meeting notes from the transcript so far, on this interval, skipping silences.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
```

And wrap the existing `Picker("Mode", selection: $settings.sidebarMode) { ... }` so it only shows when relevant — change it to:

```swift
                    if settings.livePaneMode == .suggestions {
                        Picker("Mode", selection: $settings.sidebarMode) {
```

…and add the matching closing `}` after that Picker's existing closing brace. (If wrapping the existing Picker is awkward in this view's layout, instead leave the `sidebarMode` Picker always visible — it's harmless when `livePaneMode != .suggestions` since the mode just isn't consulted. Prefer wrapping; fall back to leaving it if the surrounding container makes wrapping unclear.)

- [ ] **Step 2: Build**

Run: `cd OpenOats && swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Manual end-to-end verification**

1. Build + install: `CONFIG=debug ./scripts/build_swift_app.sh`
2. Settings → set **Live pane = Live Notes**. Confirm the interval stepper appears.
3. Start a recording and talk for a minute. Within ~one interval the third pane fills with template-style notes and shows "Updated Ns ago"; it refreshes ~every 30s only while new speech arrives (stays put during silence). Confirm the Transcript and Summary panes are unaffected.
4. Confirm NO suggestions are generated (the Suggestions pipeline is off) — e.g. enable Diagnostic logging and confirm no suggestion/surfacing activity.
5. Set **Live pane = Off** → third pane disappears; no live-notes or suggestion work runs.
6. Set **Live pane = Suggestions** → today's behavior returns (Classic/Sidecast mode picker visible and working).
7. End the meeting, hit **Generate Notes**; confirm the final output is consistent with the live pane's last state (same engine + template).

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/SidecastSettingsTab.swift
git commit -m "feat: add live pane mode + interval settings UI"
```

---

## Self-Review Notes

- **Spec coverage:** `livePaneMode` selector + pipeline gating (Tasks 1, 5); `LiveNotesEngine` reusing `NotesEngine` with ~30s/new-content/no-overlap/floor (Tasks 2-3); container/coordinator wiring (Task 4); projected state + lifecycle (Task 5); third-pane switch + panel (Task 6); settings UI + manual E2E + final-notes consistency (Task 7). Summary pane untouched; Generate Notes untouched (Non-Goals honored).
- **Type consistency:** `LivePaneMode`, `livePaneMode`, `liveNotesIntervalSeconds`, `LiveNotesScheduler.shouldRegenerate(currentCount:lastGeneratedCount:minUtterances:isGenerating:)`, `LiveNotesEngine.records(from:)`, `start(transcriptProvider:templateProvider:calendarEventProvider:)`, `clear()`, `markdown`/`isGenerating`/`lastUpdatedAt`, `liveNotesMarkdown`/`liveNotesIsGenerating`/`liveNotesUpdatedAt`, `setViewServices(...liveNotesEngine:)`, `liveNotesEngine` — consistent across tasks.
- **No placeholders:** every step has complete code. Two locate-by-matching notes (the `Utterance` init labels in Task 2's test; the StackedPanesView scope names in Task 6) are flagged with how to resolve, not left blank.
- **Untestable-by-unit pieces** (the timer loop, LLM generation, the SwiftUI panel, the settings UI) are EventKit/LLM/UI-bound and covered by the Task 7 manual E2E — an intentional, stated gap; the regeneration decision and transcript adapter are unit-tested.
