# Live Summary Detail Slider + Fixed Sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `LiveSummaryEngine` to produce five parallel prose summaries plus four fixed section lists (Key Points / Action Items / Decisions / Open Questions) per update, and rewrite `LiveSummaryPanel` to render them with a detail slider that filters summary prose + Key Points + Open Questions by level.

**Architecture:** Keep the existing `@Observable @MainActor` engine, scripted-mode-for-tests pattern, and refresh-tick data flow. Replace the engine's state (single summary + flat `[String]`) with a level-indexed dictionary for summaries plus per-section `[SummaryItem]` lists. Update the LLM JSON schema to match. The level-5 summary is the canonical accumulating state sent back as context on each call. Item levels are locked at creation. The panel renders summary + four collapsible section blocks + a bottom slider.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 15+, `@Observable` pattern, `OpenRouterClient` for LLM calls, XCTest for unit tests.

**Spec:** `docs/specs/2026-04-20-live-summary-detail-slider-and-sections-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift` | New `SummaryItem` type, new `Mode` enum, per-level summaries, per-section item lists, new schema, new prompt, dedup + level-lock, robustness rules |
| `OpenOats/Sources/OpenOats/App/LiveSessionController.swift` | `LiveSessionState` gains per-level and per-section fields; `refreshState` copies them |
| `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` | Full rewrite: summary + four sections + bottom slider; per-section collapse via `@AppStorage` |
| `OpenOats/Sources/OpenOats/Views/StackedPanesView.swift` | Update `LiveSummaryPanel(...)` call site to pass new props + `$settings.summaryDetailLevel` binding |
| `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift` | Add `summaryDetailLevel: Int` (default 3) |
| **New:** `OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift` | Unit tests for schema parsing, dedup, level lock, robustness, clear, prompt assembly |

---

### Task 1: Add `summaryDetailLevel` to AppSettings

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`

- [ ] **Step 1: Add the backing property and accessor**

In `OpenOats/Sources/OpenOats/Settings/SettingsStore.swift`, find the existing `summaryZoom` block at lines 310-319 and add the new property immediately after the zoom block (put it near the other `summary*` properties for readability):

```swift
@ObservationIgnored nonisolated(unsafe) private var _summaryDetailLevel: Int
var summaryDetailLevel: Int {
    get { access(keyPath: \.summaryDetailLevel); return _summaryDetailLevel }
    set {
        withMutation(keyPath: \.summaryDetailLevel) {
            _summaryDetailLevel = max(1, min(5, newValue))
            defaults.set(_summaryDetailLevel, forKey: "summaryDetailLevel")
        }
    }
}
```

The clamp in the setter enforces the 1-5 range defensively.

- [ ] **Step 2: Load the default in `init`**

Find the existing defaults-loading block at around line 949 (`if defaults.object(forKey: "summaryZoom") != nil { ... }`). Add the following block immediately after the zoom defaults block (before "Collapse state defaults to expanded"):

```swift
if defaults.object(forKey: "summaryDetailLevel") != nil {
    let stored = defaults.integer(forKey: "summaryDetailLevel")
    self._summaryDetailLevel = max(1, min(5, stored))
} else {
    self._summaryDetailLevel = 3
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build --package-path OpenOats`
Expected: Build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsStore.swift
git commit -m "feat: add summaryDetailLevel to AppSettings (default 3)"
```

---

### Task 2: Add `SummaryItem` type and `Mode` enum to LiveSummaryEngine

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift`

This task introduces the new types without changing any behavior. The engine still exposes its old `accumulatedSummary` / `keyPoints` API at the end of this task.

- [ ] **Step 1: Add `SummaryItem` and `Mode` at the top of the file**

In `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift`, immediately after the `import Observation` line (line 2), add:

```swift
/// A single item in one of the live-summary sections (Key Points, Action Items, etc.).
/// `level` is 1-5 (1 = essential, 5 = minor detail). Levels are locked at creation.
struct SummaryItem: Equatable, Hashable, Sendable {
    let text: String
    let level: Int
}
```

Then inside the `LiveSummaryEngine` class declaration, immediately after the `final class LiveSummaryEngine {` line, add:

```swift
    // MARK: - Mode

    enum Mode {
        /// Normal operation — calls the LLM via `OpenRouterClient`.
        case live
        /// Test mode — returns canned JSON responses instead of calling the LLM.
        /// Responses are consumed in order; if the list is exhausted the last response repeats.
        case scripted(responses: [String])
    }
```

- [ ] **Step 2: Add `mode` stored property and update the initializer**

In the same file, find the existing init (around line 43):

```swift
init(settings: AppSettings) {
    self.settings = settings
}
```

Replace it with:

```swift
private let mode: Mode
private var scriptedResponseIndex: Int = 0

init(settings: AppSettings, mode: Mode = .live) {
    self.settings = settings
    self.mode = mode
}
```

The `scriptedResponseIndex` counter lets multiple calls in a single test walk through a list of scripted responses.

- [ ] **Step 3: Build**

Run: `swift build --package-path OpenOats`
Expected: Builds cleanly. Existing callers pass only `settings:`, so the defaulted `mode:` parameter keeps them compiling.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift
git commit -m "feat: add SummaryItem + Mode enum to LiveSummaryEngine"
```

---

### Task 3: Swap engine state, schema, and prompt (with backward-compat shims)

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift`
- Create: `OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift`

At the end of this task the engine's **internal** state is fully migrated to the new shape. For compilation continuity it still exposes computed `accumulatedSummary` and `keyPoints` properties that project out of the new state — those shims are removed in Task 7. `LiveSessionController` and `LiveSummaryPanel` are untouched in this task.

- [ ] **Step 1: Replace the observable state properties**

In `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift`, the current state block (lines 11-27) looks like:

```swift
@ObservationIgnored nonisolated(unsafe) private var _accumulatedSummary: String = ""
private(set) var accumulatedSummary: String { ... }

@ObservationIgnored nonisolated(unsafe) private var _keyPoints: [String] = []
private(set) var keyPoints: [String] { ... }

@ObservationIgnored nonisolated(unsafe) private var _isGenerating: Bool = false
private(set) var isGenerating: Bool { ... }
```

Replace that entire block with:

```swift
@ObservationIgnored nonisolated(unsafe) private var _summariesByLevel: [Int: String] = [:]
private(set) var summariesByLevel: [Int: String] {
    get { access(keyPath: \.summariesByLevel); return _summariesByLevel }
    set { withMutation(keyPath: \.summariesByLevel) { _summariesByLevel = newValue } }
}

@ObservationIgnored nonisolated(unsafe) private var _keyPointsItems: [SummaryItem] = []
private(set) var keyPointsItems: [SummaryItem] {
    get { access(keyPath: \.keyPointsItems); return _keyPointsItems }
    set { withMutation(keyPath: \.keyPointsItems) { _keyPointsItems = newValue } }
}

@ObservationIgnored nonisolated(unsafe) private var _actionItems: [SummaryItem] = []
private(set) var actionItems: [SummaryItem] {
    get { access(keyPath: \.actionItems); return _actionItems }
    set { withMutation(keyPath: \.actionItems) { _actionItems = newValue } }
}

@ObservationIgnored nonisolated(unsafe) private var _decisions: [SummaryItem] = []
private(set) var decisions: [SummaryItem] {
    get { access(keyPath: \.decisions); return _decisions }
    set { withMutation(keyPath: \.decisions) { _decisions = newValue } }
}

@ObservationIgnored nonisolated(unsafe) private var _openQuestions: [SummaryItem] = []
private(set) var openQuestions: [SummaryItem] {
    get { access(keyPath: \.openQuestions); return _openQuestions }
    set { withMutation(keyPath: \.openQuestions) { _openQuestions = newValue } }
}

@ObservationIgnored nonisolated(unsafe) private var _isGenerating: Bool = false
private(set) var isGenerating: Bool {
    get { access(keyPath: \.isGenerating); return _isGenerating }
    set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
}

// MARK: - Backward-compat shims (removed in Task 7)

/// Projects the level-3 (default baseline) summary for callers that still expect a single string.
var accumulatedSummary: String {
    summariesByLevel[3] ?? summariesByLevel[5] ?? ""
}

/// Projects key-point item texts as a flat array for callers that still expect [String].
var keyPoints: [String] {
    keyPointsItems.map(\.text)
}
```

Note: `keyPointsItems` is the new per-section list. The `keyPoints` computed shim keeps the old API working.

- [ ] **Step 2: Replace the `SummaryUpdate` Codable struct**

Find the existing struct (around line 125):

```swift
private struct SummaryUpdate: Codable {
    let summary: String
    let newKeyPoints: [String]
}
```

Replace it with:

```swift
private struct SummaryUpdate: Codable {
    let summaries: [String: String]       // keys "1"..."5"
    let newItems: NewItems

    struct NewItems: Codable {
        let keyPoints: [Item]?
        let actionItems: [Item]?
        let decisions: [Item]?
        let openQuestions: [Item]?
    }

    struct Item: Codable {
        let text: String
        let level: Int?
    }
}
```

The optional `?` on each section and on `level` lets us tolerate missing fields — we handle defaults in `performUpdate`.

- [ ] **Step 3: Replace `performUpdate(newUtterances:)`**

Find the existing method (around line 87) and replace it with:

```swift
private func performUpdate(newUtterances: [Utterance]) async {
    let previousLevel5 = summariesByLevel[5] ?? ""
    let prompt = buildPrompt(previousLevel5Summary: previousLevel5, newUtterances: newUtterances)

    let responseText: String
    switch mode {
    case .live:
        do {
            responseText = try await client.complete(
                apiKey: llmApiKey,
                model: activePrimaryModel,
                messages: prompt,
                maxTokens: 3072,
                baseURL: llmBaseURL
            )
        } catch {
            print("[LiveSummaryEngine] LLM call failed: \(error)")
            return
        }
    case .scripted(let responses):
        guard !responses.isEmpty else { return }
        let idx = min(scriptedResponseIndex, responses.count - 1)
        responseText = responses[idx]
        scriptedResponseIndex += 1
    }

    let jsonString = extractJSON(from: responseText)
    guard let data = jsonString.data(using: .utf8) else { return }

    let update: SummaryUpdate
    do {
        update = try JSONDecoder().decode(SummaryUpdate.self, from: data)
    } catch {
        print("[LiveSummaryEngine] JSON parse failed: \(error)")
        return
    }

    applyUpdate(update)
}

private func applyUpdate(_ update: SummaryUpdate) {
    // Update summaries. Skip level 5 if the model returned an empty string — keep the previous canonical state.
    var merged = summariesByLevel
    for (levelKey, text) in update.summaries {
        guard let level = Int(levelKey), (1...5).contains(level) else { continue }
        if level == 5 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        merged[level] = text
    }
    summariesByLevel = merged

    // Append new items per section (no dedup yet — Task 4 adds it).
    keyPointsItems  += (update.newItems.keyPoints     ?? []).map { toSummaryItem($0) }
    actionItems     += (update.newItems.actionItems   ?? []).map { toSummaryItem($0) }
    decisions       += (update.newItems.decisions     ?? []).map { toSummaryItem($0) }
    openQuestions   += (update.newItems.openQuestions ?? []).map { toSummaryItem($0) }
}

private func toSummaryItem(_ item: SummaryUpdate.Item) -> SummaryItem {
    let level = max(1, min(5, item.level ?? 3))
    return SummaryItem(text: item.text.trimmingCharacters(in: .whitespacesAndNewlines), level: level)
}
```

- [ ] **Step 4: Replace `buildPrompt`**

Find the existing `buildPrompt` method (around line 130) and replace it with:

```swift
private func buildPrompt(previousLevel5Summary: String, newUtterances: [Utterance]) -> [OpenRouterClient.Message] {
    let system = """
    You are a live meeting notetaker. You receive a running level-5 summary \
    of the meeting so far, the current accumulated items per section, and a \
    batch of new utterances. Produce:

    1. Five prose summaries, each a distillation of the SAME underlying content:
       - Level 5: updated running summary, incorporates the new material.
       - Levels 1-4: strict distillations of level 5, progressively tighter.
       - Level 1 is one paragraph. Level 3 is the current baseline. Level 5 is comprehensive.
       All five describe the same meeting; they differ only in density.

    2. Four lists of NEW items from only the new utterances (not already in the accumulated items shown below):
       - keyPoints:     important insights or observations
       - actionItems:   concrete next steps, with owners if mentioned
       - decisions:     decisions that were reached
       - openQuestions: unresolved questions needing follow-up
       Each item has a level 1-5 (1 = essential, 5 = minor detail).
       Leave a section's array empty if nothing new applies.

    Output valid JSON only, matching this schema:
    {
      "summaries": { "1": "...", "2": "...", "3": "...", "4": "...", "5": "..." },
      "newItems": {
        "keyPoints":     [{ "text": "...", "level": 1 }],
        "actionItems":   [{ "text": "...", "level": 2 }],
        "decisions":     [{ "text": "...", "level": 1 }],
        "openQuestions": [{ "text": "...", "level": 3 }]
      }
    }

    No prose around the JSON.
    """

    var utteranceText = ""
    for u in newUtterances {
        let speakerLabel = u.speaker.isRemote ? "Them" : "You"
        utteranceText += "\(speakerLabel): \(u.displayText)\n"
    }

    let accumulatedBlock = """
    Key Points:     \(formatAccumulated(keyPointsItems))
    Action Items:   \(formatAccumulated(actionItems))
    Decisions:      \(formatAccumulated(decisions))
    Open Questions: \(formatAccumulated(openQuestions))
    """

    let user = """
    PREVIOUS LEVEL-5 SUMMARY:
    \(previousLevel5Summary.isEmpty ? "(none yet)" : previousLevel5Summary)

    ACCUMULATED ITEMS (do not re-emit these):
    \(accumulatedBlock)

    NEW UTTERANCES:
    \(utteranceText)
    Produce the five-level summaries and any new items.
    """

    return [
        OpenRouterClient.Message(role: "system", content: system),
        OpenRouterClient.Message(role: "user", content: user),
    ]
}

private func formatAccumulated(_ items: [SummaryItem]) -> String {
    guard !items.isEmpty else { return "(none)" }
    return items.map { "• [L\($0.level)] \($0.text)" }.joined(separator: "; ")
}
```

- [ ] **Step 5: Update `clear()`**

Find the existing `clear()` (around line 75) and replace its body:

```swift
func clear() {
    updateTask?.cancel()
    updateTask = nil
    summariesByLevel = [:]
    keyPointsItems = []
    actionItems = []
    decisions = []
    openQuestions = []
    utteranceBuffer.removeAll()
    lastProcessedUtteranceID = nil
    isGenerating = false
    scriptedResponseIndex = 0
}
```

- [ ] **Step 6: Create the test file with a scripted-mode smoke test**

Create `OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

@MainActor
final class LiveSummaryEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeSettings() -> AppSettings {
        let suiteName = "com.openoats.tests.livesummary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("dummy-key", forKey: "openRouterApiKey")  // pass hasValidCredentials
        let storage = AppSettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            runMigrations: false
        )
        return AppSettings(storage: storage)
    }

    private func makeEngine(responses: [String]) -> LiveSummaryEngine {
        LiveSummaryEngine(settings: makeSettings(), mode: .scripted(responses: responses))
    }

    /// Builds a batch of 6 utterances (threshold to trigger an update).
    private func sixUtterances() -> [Utterance] {
        (0..<6).map { i in
            Utterance(
                id: UUID(),
                speaker: i % 2 == 0 ? .you : .them,
                text: "utterance \(i)",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
            )
        }
    }

    private func waitForEngineIdle(_ engine: LiveSummaryEngine, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.isGenerating && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Tests

    func testScriptedResponsePopulatesSummariesAndItems() async {
        let response = """
        {
          "summaries": {
            "1": "Tight.",
            "2": "Brief.",
            "3": "Standard.",
            "4": "Detailed.",
            "5": "Comprehensive."
          },
          "newItems": {
            "keyPoints":     [{ "text": "Point A", "level": 1 }],
            "actionItems":   [{ "text": "Do thing",  "level": 2 }],
            "decisions":     [{ "text": "Chose X",  "level": 1 }],
            "openQuestions": [{ "text": "Why Y?",   "level": 3 }]
          }
        }
        """
        let engine = makeEngine(responses: [response])
        for u in sixUtterances() { engine.onUtterance(u) }
        await waitForEngineIdle(engine)

        XCTAssertEqual(engine.summariesByLevel[1], "Tight.")
        XCTAssertEqual(engine.summariesByLevel[3], "Standard.")
        XCTAssertEqual(engine.summariesByLevel[5], "Comprehensive.")
        XCTAssertEqual(engine.keyPointsItems, [SummaryItem(text: "Point A", level: 1)])
        XCTAssertEqual(engine.actionItems,    [SummaryItem(text: "Do thing", level: 2)])
        XCTAssertEqual(engine.decisions,      [SummaryItem(text: "Chose X", level: 1)])
        XCTAssertEqual(engine.openQuestions,  [SummaryItem(text: "Why Y?", level: 3)])
    }
}
```

Note: `Utterance` initializer arguments may differ in this codebase. Open `OpenOats/Sources/OpenOats/Domain/Utterance.swift` (or search for `struct Utterance`) and adjust the initializer call above to match the actual signature. The intent is simply: six distinct utterances with `.you` / `.them` speakers.

- [ ] **Step 7: Run the test (expect PASS)**

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testScriptedResponsePopulatesSummariesAndItems`
Expected: PASS.

If the test fails because `hasValidCredentials` returns false (no OpenRouter key in the test defaults), check that `defaults.set("dummy-key", forKey: "openRouterApiKey")` is being honored by `AppSettingsStorage`. If the storage layer ignores raw defaults keys, use the typed API instead:

```swift
let settings = AppSettings(storage: storage)
settings.openRouterApiKey = "dummy-key"
```

- [ ] **Step 8: Build the full package to verify no other call sites broke**

Run: `swift build --package-path OpenOats`
Expected: Builds cleanly (the backward-compat shims keep `LiveSessionController` and `StackedPanesView` compiling).

- [ ] **Step 9: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift
git commit -m "feat: migrate LiveSummaryEngine state, schema, and prompt to leveled form"
```

---

### Task 4: Per-section dedup and level locking

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift`
- Modify: `OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift`

- [ ] **Step 1: Write a failing test for case-insensitive dedup**

In `LiveSummaryEngineTests.swift` add:

```swift
func testDuplicateItemsDroppedCaseInsensitive() async {
    let first = """
    {
      "summaries": { "1":"a","2":"a","3":"a","4":"a","5":"a" },
      "newItems": { "keyPoints": [{ "text": "Launch on April 15", "level": 1 }] }
    }
    """
    let second = """
    {
      "summaries": { "1":"b","2":"b","3":"b","4":"b","5":"b" },
      "newItems": { "keyPoints": [{ "text": "launch on april 15", "level": 5 }] }
    }
    """
    let engine = makeEngine(responses: [first, second])
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)

    XCTAssertEqual(engine.keyPointsItems, [SummaryItem(text: "Launch on April 15", level: 1)])
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testDuplicateItemsDroppedCaseInsensitive`
Expected: FAIL — the current `applyUpdate` blindly appends, so the list will contain both items.

- [ ] **Step 3: Add a dedup helper and call it from `applyUpdate`**

In `LiveSummaryEngine.swift`, replace the bare `+=` lines inside `applyUpdate` with calls to a helper. Full updated `applyUpdate`:

```swift
private func applyUpdate(_ update: SummaryUpdate) {
    var merged = summariesByLevel
    for (levelKey, text) in update.summaries {
        guard let level = Int(levelKey), (1...5).contains(level) else { continue }
        if level == 5 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        merged[level] = text
    }
    summariesByLevel = merged

    keyPointsItems  = mergedSection(existing: keyPointsItems,  incoming: update.newItems.keyPoints     ?? [])
    actionItems     = mergedSection(existing: actionItems,     incoming: update.newItems.actionItems   ?? [])
    decisions       = mergedSection(existing: decisions,       incoming: update.newItems.decisions     ?? [])
    openQuestions   = mergedSection(existing: openQuestions,   incoming: update.newItems.openQuestions ?? [])
}

private func mergedSection(existing: [SummaryItem], incoming: [SummaryUpdate.Item]) -> [SummaryItem] {
    var seen = Set(existing.map { $0.text.lowercased() })
    var result = existing
    for raw in incoming {
        let item = toSummaryItem(raw)
        guard !item.text.isEmpty else { continue }
        let key = item.text.lowercased()
        if seen.contains(key) { continue }      // dedup + implicit level-lock (original wins)
        seen.insert(key)
        result.append(item)
    }
    return result
}
```

- [ ] **Step 4: Re-run the dedup test (expect PASS)**

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testDuplicateItemsDroppedCaseInsensitive`
Expected: PASS.

- [ ] **Step 5: Write a failing test for level locking**

Add to `LiveSummaryEngineTests.swift`:

```swift
func testReemittedItemKeepsOriginalLevel() async {
    let first = """
    {
      "summaries": { "1":"a","2":"a","3":"a","4":"a","5":"a" },
      "newItems": { "keyPoints": [{ "text": "CAC under $50", "level": 1 }] }
    }
    """
    let second = """
    {
      "summaries": { "1":"b","2":"b","3":"b","4":"b","5":"b" },
      "newItems": { "keyPoints": [{ "text": "CAC under $50", "level": 4 }] }
    }
    """
    let engine = makeEngine(responses: [first, second])
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)

    XCTAssertEqual(engine.keyPointsItems.count, 1)
    XCTAssertEqual(engine.keyPointsItems.first?.level, 1, "original level must win when LLM re-emits with different level")
}
```

- [ ] **Step 6: Run test (expect PASS — dedup already implicitly enforces level lock)**

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testReemittedItemKeepsOriginalLevel`
Expected: PASS.

The current `mergedSection` implementation drops the incoming item entirely when the lowercased text collides — which means the existing item (with its original level) stays. Level-lock behavior is correct by construction.

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift
git commit -m "feat: per-section dedup with level-lock in LiveSummaryEngine"
```

---

### Task 5: Robustness rules (level clamping, malformed JSON, empty level-5)

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift`
- Modify: `OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift`

Most of the robustness is already in place from Task 3 (optional fields, level clamp in `toSummaryItem`, empty-level-5 skip). This task adds tests that pin those behaviors and one missing behavior.

- [ ] **Step 1: Write tests for level clamping**

Add to `LiveSummaryEngineTests.swift`:

```swift
func testItemLevelClampedIntoRange() async {
    let response = """
    {
      "summaries": { "1":"a","2":"a","3":"a","4":"a","5":"a" },
      "newItems": {
        "keyPoints": [
          { "text": "too low",  "level": 0 },
          { "text": "too high", "level": 99 }
        ]
      }
    }
    """
    let engine = makeEngine(responses: [response])
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)

    XCTAssertEqual(engine.keyPointsItems, [
        SummaryItem(text: "too low", level: 1),
        SummaryItem(text: "too high", level: 5),
    ])
}

func testItemMissingLevelDefaultsToThree() async {
    let response = """
    {
      "summaries": { "1":"a","2":"a","3":"a","4":"a","5":"a" },
      "newItems": { "keyPoints": [{ "text": "no level" }] }
    }
    """
    let engine = makeEngine(responses: [response])
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)

    XCTAssertEqual(engine.keyPointsItems, [SummaryItem(text: "no level", level: 3)])
}
```

- [ ] **Step 2: Run tests (expect PASS)**

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testItemLevelClampedIntoRange`
Expected: PASS.

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testItemMissingLevelDefaultsToThree`
Expected: PASS.

Both should pass because `toSummaryItem` already clamps and defaults.

- [ ] **Step 3: Write a test for missing section**

Add:

```swift
func testMissingSectionTreatedAsEmpty() async {
    let response = """
    {
      "summaries": { "1":"a","2":"a","3":"a","4":"a","5":"a" },
      "newItems": { "keyPoints": [{ "text": "K", "level": 1 }] }
    }
    """
    let engine = makeEngine(responses: [response])
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)

    XCTAssertEqual(engine.keyPointsItems.count, 1)
    XCTAssertTrue(engine.actionItems.isEmpty)
    XCTAssertTrue(engine.decisions.isEmpty)
    XCTAssertTrue(engine.openQuestions.isEmpty)
}
```

- [ ] **Step 4: Run (expect PASS)**

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testMissingSectionTreatedAsEmpty`
Expected: PASS.

- [ ] **Step 5: Write a test for empty level-5 preserving canonical state**

Add:

```swift
func testEmptyLevel5DoesNotOverwriteCanonical() async {
    let first = """
    {
      "summaries": { "1":"L1","2":"L2","3":"L3","4":"L4","5":"canonical" },
      "newItems": {}
    }
    """
    let second = """
    {
      "summaries": { "1":"new1","2":"new2","3":"new3","4":"new4","5":"" },
      "newItems": {}
    }
    """
    let engine = makeEngine(responses: [first, second])
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)

    XCTAssertEqual(engine.summariesByLevel[5], "canonical", "empty level-5 must not overwrite prior canonical summary")
    XCTAssertEqual(engine.summariesByLevel[1], "new1")
    XCTAssertEqual(engine.summariesByLevel[3], "new3")
}
```

- [ ] **Step 6: Run (expect PASS)**

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testEmptyLevel5DoesNotOverwriteCanonical`
Expected: PASS. The empty-level-5 skip is already in `applyUpdate`.

- [ ] **Step 7: Write a test for malformed JSON not corrupting state**

Add:

```swift
func testMalformedJSONLeavesStateIntact() async {
    let good = """
    {
      "summaries": { "1":"a","2":"a","3":"a","4":"a","5":"good" },
      "newItems": { "keyPoints": [{ "text": "K", "level": 1 }] }
    }
    """
    let bad = "not valid json at all {{{"
    let engine = makeEngine(responses: [good, bad])
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)

    XCTAssertEqual(engine.summariesByLevel[5], "good")
    XCTAssertEqual(engine.keyPointsItems.count, 1)
    XCTAssertFalse(engine.isGenerating, "isGenerating must reset even on parse failure")
}
```

- [ ] **Step 8: Run (expect PASS)**

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testMalformedJSONLeavesStateIntact`
Expected: PASS.

If `isGenerating` does not reset after a parse failure, check the `defer` block at the original line 65 (it resets on the `Task` path that wraps `performUpdate`). Confirm that the `print` statement in `performUpdate` on parse failure falls through to the wrapping `defer`. If not, guarantee the reset by adding a `defer { /* reset in wrapper */ }` or returning — no state is modified on parse failure, and the outer `updateTask` block's defer handles `isGenerating`.

- [ ] **Step 9: Write a test for clear()**

Add:

```swift
func testClearResetsAllState() async {
    let response = """
    {
      "summaries": { "1":"a","2":"a","3":"a","4":"a","5":"a" },
      "newItems": {
        "keyPoints":     [{ "text": "K", "level": 1 }],
        "actionItems":   [{ "text": "A", "level": 2 }],
        "decisions":     [{ "text": "D", "level": 1 }],
        "openQuestions": [{ "text": "Q", "level": 3 }]
      }
    }
    """
    let engine = makeEngine(responses: [response])
    for u in sixUtterances() { engine.onUtterance(u) }
    await waitForEngineIdle(engine)

    engine.clear()

    XCTAssertTrue(engine.summariesByLevel.isEmpty)
    XCTAssertTrue(engine.keyPointsItems.isEmpty)
    XCTAssertTrue(engine.actionItems.isEmpty)
    XCTAssertTrue(engine.decisions.isEmpty)
    XCTAssertTrue(engine.openQuestions.isEmpty)
    XCTAssertFalse(engine.isGenerating)
}
```

- [ ] **Step 10: Run (expect PASS)**

Run: `swift test --package-path OpenOats --filter LiveSummaryEngineTests/testClearResetsAllState`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift
git commit -m "test: robustness rules for LiveSummaryEngine (clamping, malformed JSON, clear)"
```

---

### Task 6: Update `LiveSessionState` and `refreshState`

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`

- [ ] **Step 1: Swap state fields on `LiveSessionState`**

In `OpenOats/Sources/OpenOats/App/LiveSessionController.swift`, find lines 35-37:

```swift
var liveSummary: String = ""
var liveKeyPoints: [String] = []
var liveSummaryIsGenerating: Bool = false
```

Replace with:

```swift
var liveSummariesByLevel: [Int: String] = [:]
var liveKeyPoints:     [SummaryItem] = []
var liveActionItems:   [SummaryItem] = []
var liveDecisions:     [SummaryItem] = []
var liveOpenQuestions: [SummaryItem] = []
var liveSummaryIsGenerating: Bool = false
```

Note: we're keeping the name `liveKeyPoints` but changing its type from `[String]` to `[SummaryItem]`. That'll cascade through to the panel, which we rewrite in Task 7.

- [ ] **Step 2: Update `refreshState`**

In the same file, find the block at lines 586-592:

```swift
let summaryEngine = coordinator.liveSummaryEngine
set(\.liveSummary, summaryEngine?.accumulatedSummary ?? "")
set(\.liveSummaryIsGenerating, summaryEngine?.isGenerating ?? false)
let nextKeyPoints = summaryEngine?.keyPoints ?? []
if state.liveKeyPoints != nextKeyPoints {
    state.liveKeyPoints = nextKeyPoints
}
```

Replace with:

```swift
let summaryEngine = coordinator.liveSummaryEngine
set(\.liveSummaryIsGenerating, summaryEngine?.isGenerating ?? false)

let nextSummaries = summaryEngine?.summariesByLevel ?? [:]
if state.liveSummariesByLevel != nextSummaries {
    state.liveSummariesByLevel = nextSummaries
}
let nextKeyPoints = summaryEngine?.keyPointsItems ?? []
if state.liveKeyPoints != nextKeyPoints {
    state.liveKeyPoints = nextKeyPoints
}
let nextActions = summaryEngine?.actionItems ?? []
if state.liveActionItems != nextActions {
    state.liveActionItems = nextActions
}
let nextDecisions = summaryEngine?.decisions ?? []
if state.liveDecisions != nextDecisions {
    state.liveDecisions = nextDecisions
}
let nextOpenQs = summaryEngine?.openQuestions ?? []
if state.liveOpenQuestions != nextOpenQs {
    state.liveOpenQuestions = nextOpenQs
}
```

- [ ] **Step 3: Build**

Run: `swift build --package-path OpenOats`
Expected: `LiveSessionController.swift` compiles. `StackedPanesView.swift` will now fail to compile because its `LiveSummaryPanel(...)` call passes `summary: controllerState.liveSummary` and `keyPoints: controllerState.liveKeyPoints` — those fields no longer exist in the expected types. That's expected; Task 7 fixes it.

The engine's backward-compat shims (`accumulatedSummary`, `keyPoints`) still exist but are no longer used — they'll be removed in Task 7.

- [ ] **Step 4: Run existing tests that touch `LiveSessionController`**

Run: `swift test --package-path OpenOats --filter LiveSessionControllerTests`
Expected: All existing tests still pass. (`StackedPanesView` compile failure is a package-build issue — tests should still compile since they don't reference the view.)

If `LiveSessionControllerTests` fails to compile because it references `state.liveSummary` or `state.liveKeyPoints: [String]`, update those assertions to use the new field names/types.

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/LiveSessionController.swift
git commit -m "refactor: LiveSessionState exposes per-level summaries and per-section items"
```

Don't worry that the package as a whole doesn't build right now — Task 7 restores that.

---

### Task 7: Rewrite `LiveSummaryPanel`, update `StackedPanesView`, remove engine shims

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` (rewrite)
- Modify: `OpenOats/Sources/OpenOats/Views/StackedPanesView.swift`
- Modify: `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift` (remove shims)

- [ ] **Step 1: Rewrite `LiveSummaryPanel.swift`**

Replace the entire contents of `OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift` with:

```swift
import SwiftUI

struct LiveSummaryPanel: View {
    let summariesByLevel: [Int: String]
    let keyPoints:      [SummaryItem]
    let actionItems:    [SummaryItem]
    let decisions:      [SummaryItem]
    let openQuestions:  [SummaryItem]
    let isGenerating: Bool
    @Binding var detailLevel: Int
    var zoom: Double = 1.0

    @AppStorage("liveSummary.collapsed.keyPoints")     private var keyPointsCollapsed     = false
    @AppStorage("liveSummary.collapsed.actionItems")   private var actionItemsCollapsed   = false
    @AppStorage("liveSummary.collapsed.decisions")     private var decisionsCollapsed     = false
    @AppStorage("liveSummary.collapsed.openQuestions") private var openQuestionsCollapsed = false

    @State private var previousSummary: String = ""
    @State private var previousItemIDs: [String: Set<String>] = [:]   // section name → lowercased texts
    @State private var highlightSummary: Bool = false
    @State private var highlightedItemTexts: Set<String> = []

    private var currentSummary: String {
        if let exact = summariesByLevel[detailLevel], !exact.isEmpty { return exact }
        for fallback in [detailLevel - 1, detailLevel + 1, detailLevel - 2, detailLevel + 2, detailLevel - 3, detailLevel + 3, detailLevel - 4, detailLevel + 4] {
            if let candidate = summariesByLevel[fallback], !candidate.isEmpty {
                return candidate
            }
        }
        return ""
    }

    private var visibleKeyPoints:     [SummaryItem] { keyPoints.filter     { $0.level <= detailLevel } }
    private var visibleOpenQuestions: [SummaryItem] { openQuestions.filter { $0.level <= detailLevel } }

    private var allEmpty: Bool {
        currentSummary.isEmpty
            && visibleKeyPoints.isEmpty
            && actionItems.isEmpty
            && decisions.isEmpty
            && visibleOpenQuestions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if allEmpty {
                        emptyState
                    } else {
                        if !currentSummary.isEmpty { summarySection }
                        if !visibleKeyPoints.isEmpty {
                            sectionBlock(title: "Key Points", items: visibleKeyPoints, collapsed: $keyPointsCollapsed)
                        }
                        if !actionItems.isEmpty {
                            sectionBlock(title: "Action Items", items: actionItems, collapsed: $actionItemsCollapsed)
                        }
                        if !decisions.isEmpty {
                            sectionBlock(title: "Decisions", items: decisions, collapsed: $decisionsCollapsed)
                        }
                        if !visibleOpenQuestions.isEmpty {
                            sectionBlock(title: "Open Questions", items: visibleOpenQuestions, collapsed: $openQuestionsCollapsed)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            detailSlider
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .onChange(of: currentSummary) { _, newValue in
            if newValue != previousSummary && !previousSummary.isEmpty {
                triggerSummaryHighlight()
            }
            previousSummary = newValue
        }
        .onChange(of: keyPoints)     { _, new in diffAndHighlight(section: "keyPoints",     items: new) }
        .onChange(of: actionItems)   { _, new in diffAndHighlight(section: "actionItems",   items: new) }
        .onChange(of: decisions)     { _, new in diffAndHighlight(section: "decisions",     items: new) }
        .onChange(of: openQuestions) { _, new in diffAndHighlight(section: "openQuestions", items: new) }
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
            Text(currentSummary)
                .font(.system(size: 13 * zoom))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightSummary ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func sectionBlock(title: String, items: [SummaryItem], collapsed: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if !collapsed.wrappedValue {
                ForEach(items, id: \.text) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 13 * zoom))
                            .foregroundStyle(.secondary)
                        Text(item.text)
                            .font(.system(size: 13 * zoom))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(highlightedItemTexts.contains(item.text) ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color.clear))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Slider

    private var detailSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Detail")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(detailLevel) },
                        set: { detailLevel = max(1, min(5, Int($0.rounded()))) }
                    ),
                    in: 1...5,
                    step: 1
                )
            }
            HStack(spacing: 0) {
                ForEach(Array(sliderLabels.enumerated()), id: \.offset) { idx, label in
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(idx + 1 == detailLevel ? .primary : .tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private let sliderLabels = ["Tight", "Brief", "Standard", "Detailed", "Comprehensive"]

    // MARK: - Diff Highlighting

    private func triggerSummaryHighlight() {
        withAnimation(.easeIn(duration: 0.2)) { highlightSummary = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) { highlightSummary = false }
        }
    }

    private func diffAndHighlight(section: String, items: [SummaryItem]) {
        let newTexts = Set(items.map { $0.text.lowercased() })
        let oldTexts = previousItemIDs[section] ?? []
        let added = newTexts.subtracting(oldTexts)
        previousItemIDs[section] = newTexts

        let addedDisplayTexts = items
            .filter { added.contains($0.text.lowercased()) }
            .map(\.text)

        guard !addedDisplayTexts.isEmpty else { return }
        withAnimation(.easeIn(duration: 0.2)) {
            highlightedItemTexts.formUnion(addedDisplayTexts)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeOut(duration: 0.5)) {
                highlightedItemTexts.subtract(addedDisplayTexts)
            }
        }
    }
}
```

- [ ] **Step 2: Update `StackedPanesView` call site**

In `OpenOats/Sources/OpenOats/Views/StackedPanesView.swift`, find the `LiveSummaryPanel(...)` call (around line 35):

```swift
LiveSummaryPanel(
    summary: controllerState.liveSummary,
    keyPoints: controllerState.liveKeyPoints,
    isGenerating: controllerState.liveSummaryIsGenerating,
    zoom: settings.summaryZoom
)
```

Replace with:

```swift
LiveSummaryPanel(
    summariesByLevel: controllerState.liveSummariesByLevel,
    keyPoints:       controllerState.liveKeyPoints,
    actionItems:     controllerState.liveActionItems,
    decisions:       controllerState.liveDecisions,
    openQuestions:   controllerState.liveOpenQuestions,
    isGenerating:    controllerState.liveSummaryIsGenerating,
    detailLevel:     $settings.summaryDetailLevel,
    zoom:            settings.summaryZoom
)
```

- [ ] **Step 3: Remove the backward-compat shims from `LiveSummaryEngine`**

In `OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift`, find and delete the shim block added in Task 3 Step 1:

```swift
// MARK: - Backward-compat shims (removed in Task 7)

var accumulatedSummary: String { ... }
var keyPoints: [String] { ... }
```

- [ ] **Step 4: Build the whole package**

Run: `swift build --package-path OpenOats`
Expected: Builds cleanly.

Common failures:
- If `$settings.summaryDetailLevel` binding fails to resolve, verify Task 1's property has a public setter (no `private(set)`) — `@Observable` with custom getter/setter supports binding via `$` as long as the accessor is exposed.
- If `SummaryItem` isn't visible from `LiveSummaryPanel.swift` or `StackedPanesView.swift`, confirm the type is declared at file scope in `LiveSummaryEngine.swift` (not nested inside the class).

- [ ] **Step 5: Run the full test suite**

Run: `swift test --package-path OpenOats`
Expected: All tests pass, including the `LiveSummaryEngineTests` added in tasks 3-5.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/LiveSummaryPanel.swift OpenOats/Sources/OpenOats/Views/StackedPanesView.swift OpenOats/Sources/OpenOats/Intelligence/LiveSummaryEngine.swift
git commit -m "feat: LiveSummaryPanel rewrite with detail slider + four fixed sections"
```

---

### Task 8: Manual QA

No code changes here — this is an in-app validation pass against the spec's success criteria.

- [ ] **Step 1: Launch the app in debug**

Run from Xcode (open `OpenOats/Package.swift`, select the `OpenOats` scheme, run) or build the debug binary:

```bash
swift build --package-path OpenOats
# then launch the built binary from the debug build products
```

- [ ] **Step 2: Start a meeting and let the summary populate**

- Start a live session.
- Speak or play a long enough recording to trigger at least 2-3 summary updates (6+ utterances per update).
- Confirm the summary prose updates and at least one section (Key Points, Action Items, Decisions, or Open Questions) accumulates items.

- [ ] **Step 3: Verify the slider**

- Drag the slider from Tight (1) to Comprehensive (5).
- Expected: the Meeting Summary prose changes density on each step. Key Points and Open Questions lists grow/shrink as you slide. Action Items and Decisions are unaffected.
- Slider drag is instant — no network request, no "generating..." spinner.

- [ ] **Step 4: Verify per-section collapse**

- Click each section header's chevron. Each section collapses/expands independently.
- Quit and relaunch the app. Collapse state persists.

- [ ] **Step 5: Verify highlights**

- When a new summary arrives, the summary block briefly highlights.
- When a new item appears in any section, that item briefly highlights.

- [ ] **Step 6: Verify session clear**

- Stop and restart the session. Confirm all state resets (summary blank, all four sections empty, slider position retained across sessions as a user preference).

- [ ] **Step 7: Cross-provider smoke check (optional)**

- If Ollama, MLX, or OpenAI-compatible are configured: run a short session with each. Confirm the prompt still yields valid JSON matching the schema.
- If the model is chatty and wraps output in markdown code fences, the existing `extractJSON` helper handles that.

- [ ] **Step 8: Commit any last cleanup**

If manual QA surfaces fixable nits (typography, label wording), apply them as a small commit:

```bash
git add <files>
git commit -m "polish: live summary panel manual-QA tweaks"
```

---

## Self-Review Checklist

Before handing off, re-verify:

- [ ] Every spec section has a corresponding task (engine state, schema, prompt, accumulation, robustness, UI, settings, tests, non-goals understood)
- [ ] No "TBD" / "TODO" / "handle error" without concrete code
- [ ] Type names match across tasks: `SummaryItem` (not `LiveSummaryItem`), `summariesByLevel` (not `levelSummaries`), `keyPointsItems` as the engine property vs `keyPoints` on the panel/state
- [ ] Test file path is consistent: `OpenOats/Tests/OpenOatsTests/LiveSummaryEngineTests.swift`
- [ ] Build + test commands use the `--package-path OpenOats` prefix throughout
