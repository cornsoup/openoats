# Transcription Spelling Glossary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply a user-maintained spelling glossary to both the live and batch transcript-cleanup LLM passes so transcripts get corrected for proper nouns (people, companies, technical terms) regardless of which transcription backend produced them.

**Architecture:** A new tiny `SpellingGlossary` helper parses and unions the global glossary (`AppSettings.transcriptionCustomVocabulary`, already there) with optional per-folder additions (new `glossary` field on `NotesFolderDefinition`). The two existing cleanup passes — `LiveTranscriptCleaner` and `BatchTextCleaner` — append a glossary instruction block to their system prompts when terms are present. UI changes are minimal: rename the existing Settings section label and add an optional disclosure to the folder editor sheet.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 15+, `@Observable` pattern, XCTest, `OpenRouterClient` for LLM calls.

**Spec:** `docs/specs/2026-05-12-transcription-spelling-glossary-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| **New:** `OpenOats/Sources/OpenOats/Intelligence/SpellingGlossary.swift` | Pure helper: parse glossary strings, union global + folder, format the prompt block. No I/O, no state. |
| **New:** `OpenOats/Tests/OpenOatsTests/SpellingGlossaryTests.swift` | Unit tests for parse / union / dedup / prompt-block formatting. |
| `OpenOats/Sources/OpenOats/Settings/SettingsTypes.swift` | Add `var glossary: String = ""` to `NotesFolderDefinition`. |
| `OpenOats/Sources/OpenOats/Intelligence/LiveTranscriptCleaner.swift` | Replace the const `systemPrompt` with a per-call computation that appends the glossary block when non-empty. Uses only the global glossary (no folder at live time). |
| `OpenOats/Sources/OpenOats/Intelligence/BatchTextCleaner.swift` | Replace the const `systemPrompt` with a static helper that accepts the resolved glossary and appends the block when non-empty. |
| `OpenOats/Sources/OpenOats/App/NotesController.swift` | At the `batchTextCleaner.cleanup(...)` call site, resolve the session's folder glossary (if any) and pass it through. |
| `OpenOats/Sources/OpenOats/Views/SettingsView.swift` | Rename the existing "Custom Vocabulary" section label to "Spelling Glossary"; update the help text. |
| `OpenOats/Sources/OpenOats/Views/FolderEditorSheetView.swift` | Add an optional disclosure with a `TextEditor` for the per-folder glossary additions. |

---

### Task 1: `SpellingGlossary` helper + tests

A pure helper that parses glossary strings, unions global + folder, dedupes, and formats the prompt block. TDD.

**Files:**
- Create: `OpenOats/Sources/OpenOats/Intelligence/SpellingGlossary.swift`
- Create: `OpenOats/Tests/OpenOatsTests/SpellingGlossaryTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `/Users/jja/Projects/active/openoats/OpenOats/Tests/OpenOatsTests/SpellingGlossaryTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

final class SpellingGlossaryTests: XCTestCase {

    func testEmptyInputsReturnEmptyList() {
        XCTAssertEqual(SpellingGlossary.terms(global: "", folderGlossary: nil), [])
        XCTAssertEqual(SpellingGlossary.terms(global: "", folderGlossary: ""), [])
        XCTAssertEqual(SpellingGlossary.terms(global: "   \n  \n", folderGlossary: nil), [])
    }

    func testGlobalOnlyParses() {
        let result = SpellingGlossary.terms(global: "EDIR\nGoldfarb\nSmith & Jones LLP", folderGlossary: nil)
        XCTAssertEqual(result, ["EDIR", "Goldfarb", "Smith & Jones LLP"])
    }

    func testFolderOnlyParses() {
        let result = SpellingGlossary.terms(global: "", folderGlossary: "Quirin\nAcme Corp")
        XCTAssertEqual(result, ["Quirin", "Acme Corp"])
    }

    func testTrimsWhitespacePerLine() {
        let result = SpellingGlossary.terms(global: "  EDIR  \n\tGoldfarb\n", folderGlossary: nil)
        XCTAssertEqual(result, ["EDIR", "Goldfarb"])
    }

    func testSkipsEmptyLinesAndComments() {
        let result = SpellingGlossary.terms(global: "EDIR\n\n# notes about names\nGoldfarb\n   #also a comment\n", folderGlossary: nil)
        XCTAssertEqual(result, ["EDIR", "Goldfarb"])
    }

    func testUnionGlobalThenFolderPreservingOrder() {
        let result = SpellingGlossary.terms(global: "EDIR\nGoldfarb", folderGlossary: "Acme Corp\nQuirin")
        XCTAssertEqual(result, ["EDIR", "Goldfarb", "Acme Corp", "Quirin"])
    }

    func testCaseInsensitiveDedup() {
        let result = SpellingGlossary.terms(global: "EDIR\nGoldfarb", folderGlossary: "edir\nGoldfarb\nAcme Corp")
        XCTAssertEqual(result, ["EDIR", "Goldfarb", "Acme Corp"])
    }

    func testPromptBlockEmptyForEmptyTerms() {
        XCTAssertEqual(SpellingGlossary.promptBlock(terms: []), "")
    }

    func testPromptBlockContainsTermsAndInstructions() {
        let block = SpellingGlossary.promptBlock(terms: ["EDIR", "Goldfarb"])
        XCTAssertTrue(block.contains("SPELLING GLOSSARY"))
        XCTAssertTrue(block.contains("- EDIR"))
        XCTAssertTrue(block.contains("- Goldfarb"))
        XCTAssertTrue(block.contains("phonetically"))
        XCTAssertTrue(block.contains("Do NOT"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path OpenOats --filter SpellingGlossaryTests`
Expected: FAIL with "cannot find 'SpellingGlossary' in scope".

- [ ] **Step 3: Implement the helper**

Create `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Intelligence/SpellingGlossary.swift`:

```swift
import Foundation

/// Parses and unions the user's spelling glossary so transcript-cleanup
/// passes can include it in their LLM system prompts. Pure, stateless.
enum SpellingGlossary {

    /// Returns the deduplicated list of glossary terms for a session.
    ///
    /// - `global` is the user's app-wide list, one term per line. Empty lines
    ///   and lines starting with `#` are dropped. Whitespace per line is
    ///   trimmed.
    /// - `folderGlossary` is the optional per-folder additions in the same
    ///   format. Pass `nil` (or `""`) when there is no folder.
    ///
    /// Order is global-first, then folder additions. Dedup is case-
    /// insensitive on the trimmed term; the first occurrence wins.
    static func terms(global: String, folderGlossary: String?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in parse(global) {
            let key = line.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(line)
        }
        if let folderGlossary {
            for line in parse(folderGlossary) {
                let key = line.lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                result.append(line)
            }
        }
        return result
    }

    /// Returns the prompt block that the cleaners append to their system
    /// prompt. Empty string when there are no terms, so callers can
    /// unconditionally append.
    static func promptBlock(terms: [String]) -> String {
        guard !terms.isEmpty else { return "" }
        let bullets = terms.map { "- \($0)" }.joined(separator: "\n")
        return """

        SPELLING GLOSSARY (proper names and terms used by the speaker; transcription errors are common with these):

        \(bullets)

        If a word in the transcript phonetically matches one of these but is spelled differently, replace it with the version from this list. Do NOT modify words that don't phonetically match a glossary entry. Do NOT add these names to text where they don't belong.
        """
    }

    private static func parse(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard !trimmed.hasPrefix("#") else { return nil }
            return trimmed
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path OpenOats --filter SpellingGlossaryTests`
Expected: 9/9 pass.

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/SpellingGlossary.swift OpenOats/Tests/OpenOatsTests/SpellingGlossaryTests.swift
git commit -m "feat: add SpellingGlossary helper for transcript cleanup prompts"
```

---

### Task 2: Add `glossary` field to `NotesFolderDefinition`

Backward-compatible Codable addition. Default `""` means no change for existing saved folders.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Settings/SettingsTypes.swift`

- [ ] **Step 1: Add the field and update the initializer**

In `OpenOats/Sources/OpenOats/Settings/SettingsTypes.swift`, the existing `NotesFolderDefinition` is around line 52:

```swift
struct NotesFolderDefinition: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var path: String
    var color: NotesFolderColor

    init(id: UUID = UUID(), path: String, color: NotesFolderColor) {
        self.id = id
        self.path = Self.normalizePath(path) ?? path
        self.color = color
    }
    // ...
}
```

Replace with:

```swift
struct NotesFolderDefinition: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var path: String
    var color: NotesFolderColor
    /// Optional spelling-glossary additions specific to meetings filed in
    /// this folder. One term per line. Empty for folders with no additions.
    var glossary: String

    init(id: UUID = UUID(), path: String, color: NotesFolderColor, glossary: String = "") {
        self.id = id
        self.path = Self.normalizePath(path) ?? path
        self.color = color
        self.glossary = glossary
    }
    // ... (rest of the type unchanged)
}
```

The `glossary: String = ""` default makes `init` calls without it keep compiling. For Codable, missing keys decode as the default for the type only if the property has a default — Swift's synthesized Codable conformance respects the default initializer value for missing keys when using the synthesized `init(from:)`. So old saved folders decode with `glossary = ""`.

- [ ] **Step 2: Build**

Run: `swift build --package-path OpenOats`
Expected: clean build. If existing `NotesFolderDefinition(id:path:color:)` call sites elsewhere compile cleanly, the default parameter is doing its job.

If the build fails because of Codable decoding (Swift's synthesis may or may not back-fill missing keys depending on version), add an explicit `init(from decoder:)`:

```swift
init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(UUID.self, forKey: .id)
    self.path = try container.decode(String.self, forKey: .path)
    self.color = try container.decode(NotesFolderColor.self, forKey: .color)
    self.glossary = try container.decodeIfPresent(String.self, forKey: .glossary) ?? ""
}
```

(Only add this if the default-value approach fails.)

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Settings/SettingsTypes.swift
git commit -m "feat: add per-folder spelling glossary field to NotesFolderDefinition"
```

---

### Task 3: Extend `LiveTranscriptCleaner` prompt

The live cleaner uses only the global glossary (the session has no folder at live time).

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/LiveTranscriptCleaner.swift`

- [ ] **Step 1: Convert the constant `systemPrompt` to a computed property**

Open `OpenOats/Sources/OpenOats/Intelligence/LiveTranscriptCleaner.swift`. Find the constant `private let systemPrompt = """..."""` (around line 19) and rename it. Replace:

```swift
private let systemPrompt = """
...existing system prompt body...
"""
```

with:

```swift
private let baseSystemPrompt = """
...same existing system prompt body...
"""

/// Returns the system prompt with the user's global spelling glossary
/// appended (empty append when the user has no glossary set).
private var systemPrompt: String {
    let terms = SpellingGlossary.terms(
        global: settings.transcriptionCustomVocabulary,
        folderGlossary: nil
    )
    return baseSystemPrompt + SpellingGlossary.promptBlock(terms: terms)
}
```

The cleaner already holds a `settings: AppSettings` reference (used by `clean(_:)`). If it doesn't — check the existing initializer and add a `let settings: AppSettings` stored property plus `init(..., settings: AppSettings)` parameter, then update the call site in `AppContainer.swift` to pass `settings`.

- [ ] **Step 2: Build**

Run: `swift build --package-path OpenOats`
Expected: clean build. If `settings` isn't already a member, follow the wire-through described above.

- [ ] **Step 3: Verify behavior unchanged when glossary is empty**

Run the existing live-cleaner tests (if any):

```bash
swift test --package-path OpenOats --filter LiveTranscriptCleanerTests 2>&1 | tail -5
```

Expected: same pass/fail count as before this change. If no tests exist for this class, just confirm `swift build` succeeds.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/LiveTranscriptCleaner.swift OpenOats/Sources/OpenOats/App/AppContainer.swift
git commit -m "feat: LiveTranscriptCleaner prompt includes global spelling glossary"
```

(The `AppContainer.swift` is only in the staged list if you had to wire `settings` through.)

---

### Task 4: Extend `BatchTextCleaner` prompt + call-site folder resolution

The batch cleaner accepts the resolved glossary as a parameter. The call site in `NotesController` does the folder lookup.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Intelligence/BatchTextCleaner.swift`
- Modify: `OpenOats/Sources/OpenOats/App/NotesController.swift`

- [ ] **Step 1: Update `BatchTextCleaner.systemPrompt` to a static function**

Open `OpenOats/Sources/OpenOats/Intelligence/BatchTextCleaner.swift`. Find the constant (around line 37):

```swift
private nonisolated static let systemPrompt = """
...existing system prompt body...
"""
```

Replace with:

```swift
private nonisolated static let baseSystemPrompt = """
...same existing system prompt body...
"""

/// Builds the system prompt with the resolved spelling glossary appended
/// (empty append when there are no terms).
private nonisolated static func makeSystemPrompt(glossaryTerms: [String]) -> String {
    baseSystemPrompt + SpellingGlossary.promptBlock(terms: glossaryTerms)
}
```

- [ ] **Step 2: Update `cleanup(records:settings:)` to accept and apply the glossary**

Find the existing signature (around line 53):

```swift
func cleanup(records: [SessionRecord], settings: AppSettings) async -> [SessionRecord] {
```

Add a `glossaryTerms` parameter at the end with a default of `[]` so old callers keep working:

```swift
func cleanup(
    records: [SessionRecord],
    settings: AppSettings,
    glossaryTerms: [String] = []
) async -> [SessionRecord] {
```

Inside the function, find where the system prompt is used (around line 240 — the `.init(role: "system", content: systemPrompt)` line). Replace `systemPrompt` with a local resolution:

```swift
let resolvedSystemPrompt = Self.makeSystemPrompt(glossaryTerms: glossaryTerms)

let messages: [OpenRouterClient.Message] = [
    .init(role: "system", content: resolvedSystemPrompt),
    .init(role: "user", content: prompt),
]
```

If `systemPrompt` is referenced more than once in `cleanup(...)`, compute `resolvedSystemPrompt` once at the top of the function and use it everywhere.

- [ ] **Step 3: Update the call site in `NotesController`**

Open `OpenOats/Sources/OpenOats/App/NotesController.swift`. Find the call (around line 809):

```swift
let updated = await coordinator.batchTextCleaner.cleanup(
    records: state.loadedTranscript,
    settings: settings
)
```

Replace with:

```swift
// Resolve the session's folder glossary (if the session is filed in a folder).
let folderGlossary: String? = {
    guard let sessionID = state.selectedSessionID,
          let session = state.sessionHistory.first(where: { $0.id == sessionID }),
          let folderPath = session.folderPath,
          let folder = settings.notesFolders.first(where: { $0.path == folderPath })
    else { return nil }
    return folder.glossary
}()

let glossaryTerms = SpellingGlossary.terms(
    global: settings.transcriptionCustomVocabulary,
    folderGlossary: folderGlossary
)

let updated = await coordinator.batchTextCleaner.cleanup(
    records: state.loadedTranscript,
    settings: settings,
    glossaryTerms: glossaryTerms
)
```

If `SessionIndex.folderPath` is spelled differently in this codebase, use the actual property name (check `SessionRepository.swift`'s `SessionIndex` initializer call site for the canonical name — earlier grep showed it as `folderPath: meta.folderPath`).

- [ ] **Step 4: Build**

Run: `swift build --package-path OpenOats`
Expected: clean build.

- [ ] **Step 5: Run cleaner tests**

If `BatchTextCleanerTests` exists:

```bash
swift test --package-path OpenOats --filter BatchTextCleanerTests
```

Expected: same pass/fail count as before. The `glossaryTerms: [String] = []` default makes existing tests transparent.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Intelligence/BatchTextCleaner.swift OpenOats/Sources/OpenOats/App/NotesController.swift
git commit -m "feat: BatchTextCleaner prompt includes global + folder spelling glossary"
```

---

### Task 5: Settings UI relabel

Tiny edit: rename the existing section + update help text.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/SettingsView.swift`

- [ ] **Step 1: Update the section label**

Open `OpenOats/Sources/OpenOats/Views/SettingsView.swift`. Find the `transcriptionCustomVocabulary` block around lines 505-520 (the `TextEditor(text: $settings.transcriptionCustomVocabulary)` call). The section is likely wrapped in a `Section("Custom Vocabulary") { ... }` or has a `Text("Custom Vocabulary")` header just above. Find that label and change it to:

```swift
Section("Spelling Glossary") {
```

(Or change the `Text(...)` heading line if it's not in a Section.)

Find the help text just below (a `Text("...")` describing what the field does). Replace it with:

```swift
Text("One term per line. Names, companies, or other proper nouns the transcription model gets wrong. Used to bias cloud transcription and to correct mistakes in any transcript via the cleanup pass.")
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
```

Match the existing font/style modifiers if they differ.

- [ ] **Step 2: Build**

Run: `swift build --package-path OpenOats`
Expected: clean build.

- [ ] **Step 3: Visual verification**

Launch the debug binary, open Settings → Intelligence tab, confirm the section is now labeled "Spelling Glossary" with the new help text. The `TextEditor` should still work and persist to `transcriptionCustomVocabulary`.

```bash
/Users/jja/Projects/active/openoats/OpenOats/.build/debug/OpenOats
```

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/SettingsView.swift
git commit -m "polish: rename Custom Vocabulary to Spelling Glossary in Settings"
```

---

### Task 6: Folder editor — per-folder glossary

Add an optional disclosure with a `TextEditor` for `folder.glossary`.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/Views/FolderEditorSheetView.swift`

- [ ] **Step 1: Inspect the existing sheet**

Open `OpenOats/Sources/OpenOats/Views/FolderEditorSheetView.swift`. The view takes bindings for path / color / focus and onSave/onCancel callbacks (per the unified-window plan). It does NOT currently know about glossary.

The cleanest extension: add an optional `@Binding var glossary: String?` parameter (nil means "don't show the glossary section"). Callers from session-level new-folder sheets pass `nil` (those sheets only set path + color and write a new folder, not edit an existing one's glossary). Callers from folder-editing flows pass the binding to the folder's glossary.

But for v1, simpler: add a non-optional `@Binding var glossary: String` parameter, default-handled in callers.

- [ ] **Step 2: Add the binding parameter and disclosure UI**

In `FolderEditorSheetView`, add a `@Binding var glossary: String` stored property near the other bindings, then update the body's `VStack` to include an optional disclosure section. After the existing color picker / path field, add:

```swift
DisclosureGroup("Spelling additions for this folder (optional)") {
    VStack(alignment: .leading, spacing: 6) {
        Text("Names and terms specific to meetings filed here. These add to your global Spelling Glossary.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        TextEditor(text: $glossary)
            .font(.system(size: 12))
            .frame(minHeight: 80, maxHeight: 160)
            .border(Color.primary.opacity(0.1))
    }
    .padding(.top, 4)
}
.font(.system(size: 12))
```

- [ ] **Step 3: Update callers to pass the binding**

Search for `FolderEditorSheetView(` to find call sites:

```bash
grep -rn "FolderEditorSheetView(" OpenOats/Sources/OpenOats/Views/
```

For each caller, add `glossary:` to the parameters. For callers that create a NEW folder (path doesn't exist yet), pass a `@State` binding to a local string. For callers that EDIT an existing folder, bind to the folder's `glossary` field.

Likely call sites: `NotesSidebarView` (session-level new folder), `NotesDetailView` (meeting-family folder editor), possibly `SettingsView` if it has a folder editor.

A representative new-folder caller looks like:

```swift
@State private var newFolderPath: String = ""
@State private var newFolderColor: NotesFolderColor = .blue
@State private var newFolderGlossary: String = ""  // NEW
// ...
FolderEditorSheetView(
    title: "New Folder",
    subtitle: "...",
    path: $newFolderPath,
    color: $newFolderColor,
    glossary: $newFolderGlossary,  // NEW
    saveDisabled: newFolderPath.isEmpty,
    pathFieldFocused: $newFolderFieldFocused,
    onSave: {
        // existing save logic — include glossary when constructing the folder:
        let folder = NotesFolderDefinition(
            path: newFolderPath,
            color: newFolderColor,
            glossary: newFolderGlossary  // NEW
        )
        settings.notesFolders.append(folder)
        // ... etc
    },
    onCancel: { /* ... */ }
)
```

For edit-existing-folder call sites, the caller already has a `NotesFolderDefinition` in hand; create a `Binding` to its `glossary` field. Idiomatic SwiftUI: pass `Binding(get: { folder.glossary }, set: { newValue in /* update folder in settings.notesFolders */ })` or, if the call site already has settings access, mutate the array element directly.

- [ ] **Step 4: Build**

Run: `swift build --package-path OpenOats`
Expected: clean build. Likely fix errors as missing `glossary:` parameter on each FolderEditorSheetView call site.

- [ ] **Step 5: Visual verification**

Launch the debug binary, right-click a meeting in the sidebar → "Move to Folder…" → "New Folder…". Expand "Spelling additions for this folder (optional)". The text editor should appear, you can type into it, save the folder, and the value persists across app restarts. Verify by reopening the editor on the same folder.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/FolderEditorSheetView.swift OpenOats/Sources/OpenOats/Views/NotesSidebarView.swift OpenOats/Sources/OpenOats/Views/NotesDetailView.swift
git commit -m "feat: per-folder spelling-glossary additions in folder editor sheet"
```

(Adjust the staged list to match the files you actually changed.)

---

### Task 7: Manual QA

No code changes — validation pass with a recording.

- [ ] **Step 1: Build and launch**

```bash
swift build --package-path OpenOats
/Users/jja/Projects/active/openoats/OpenOats/.build/debug/OpenOats
```

Confirm BuildInfo shows today's date.

- [ ] **Step 2: Add a global glossary term**

Open Settings → Intelligence → "Spelling Glossary". Add one term per line. Use at least one name that you know the transcription model gets wrong (e.g. a name a colleague's machine has spelled incorrectly in past sessions). Close Settings.

- [ ] **Step 3: Record a short session that mentions the term**

Start recording. Say the glossary term several times during a 30-second meeting. Stop.

- [ ] **Step 4: Verify the cleaned transcript uses the glossary spelling**

After cleanup completes (the "Generating notes…" / cleanup indicator finishes), open the session's transcript. The term should appear with the glossary spelling. If the raw audio is preserved (via batch retranscribe), confirm both the live and batch paths produced the correct spelling.

- [ ] **Step 5: Verify it doesn't over-correct**

Record a second short session that does NOT say the glossary term but says a word that's phonetically near it. The glossary term should NOT appear in the cleaned transcript.

- [ ] **Step 6: Per-folder QA**

Create a new folder via the sidebar context menu. Expand "Spelling additions for this folder (optional)". Add a folder-specific name. Save the folder. File a meeting into it. Confirm the folder's specific name appears in that meeting's cleaned transcript (it shouldn't appear in unrelated meetings filed elsewhere).

- [ ] **Step 7: Restart-persistence sanity**

Quit and relaunch the debug binary. Verify the global glossary content is still there in Settings, and the folder's glossary additions are still there in the folder editor.

- [ ] **Step 8: Optional polish commit**

If any rough edges surface in QA (typos in help text, alignment issues, etc.), apply small fixes:

```bash
git add <files>
git commit -m "polish: spelling glossary QA tweaks"
```

---

## Self-Review Checklist

- [ ] Spec coverage: every section in the design doc maps to a task
  - Section 1 (where correction happens) → Tasks 3 + 4
  - Section 2 (storage + UI) → Tasks 2, 5, 6
  - Section 3 (prompt addition) → Tasks 1, 3, 4
  - Section 4 (non-goals) → no task, intentional
- [ ] No "TBD" / "TODO" / "implement later" / "fill in details" anywhere
- [ ] Type names consistent: `SpellingGlossary`, `NotesFolderDefinition`, `LiveTranscriptCleaner`, `BatchTextCleaner`
- [ ] Build/test commands use `--package-path OpenOats`
- [ ] Migration concern (`Codable` default-value handling for `NotesFolderDefinition.glossary`) addressed with a fallback (Task 2 Step 2)
