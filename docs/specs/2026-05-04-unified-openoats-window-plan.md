# Unified OpenOats Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse OpenOats' separate `main` (recording) and `notes` (past meetings) windows into a single primary "OpenOats" window with a sidebar of past meetings, a recording-or-detail right pane, and a persistent control bar. Past meetings open in their own per-session pop-out windows on demand.

**Architecture:** Pure UI restructure. No engine-layer changes. The 3,713-line `NotesView` is decomposed into reusable `NotesSidebarView` + `NotesDetailView` so both the new `UnifiedOpenOatsView` and the new `PastMeetingWindowView` can host them. A new session-scoped `PastMeetingViewModel` owns the pop-out's data. Window scenes change in `OpenOatsApp.swift`; menus, deep links, and the menu bar redirect to the unified window.

**Tech Stack:** Swift 6.2, SwiftUI, macOS 15+, `@Observable` pattern, XCTest.

**Spec:** `docs/specs/2026-05-04-unified-openoats-window-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| **New:** `OpenOats/Sources/OpenOats/Views/NotesSidebarView.swift` | Sidebar-only chrome extracted from `NotesView`: session list, group headers, context menus, rename + folder + add-transcript sheets. Owns its own sheet state. |
| **New:** `OpenOats/Sources/OpenOats/Views/NotesDetailView.swift` | Detail-only chrome extracted from `NotesView`: meeting title, notes/transcript/scratchpad/attachments, regenerate buttons, restore-transcript dialog. Owns its own sheet state. |
| **New:** `OpenOats/Sources/OpenOats/App/PastMeetingViewModel.swift` | Session-scoped view model: loads one session's records/notes/scratchpad from `SessionRepository`, triggers regeneration via `NotesEngine`, observes repo for cross-window sync. |
| **New:** `OpenOats/Sources/OpenOats/Views/PastMeetingWindowView.swift` | Pop-out window root: hosts `PastMeetingViewModel` and renders `NotesDetailView`. Window title bound to session title. |
| **New:** `OpenOats/Sources/OpenOats/Views/UnifiedOpenOatsView.swift` | Unified primary window root: sidebar + state-machine detail (recording / idle+selected / idle+empty) + persistent `ControlBar`. |
| **New:** `OpenOats/Tests/OpenOatsTests/PastMeetingViewModelTests.swift` | Unit tests for the new view model (load, regenerate, repo observation). |
| `OpenOats/Sources/OpenOats/Views/NotesView.swift` | After Task 1+2 extraction: a thin orchestrator that creates the controller and arranges sidebar + detail. Deleted in Task 7. |
| `OpenOats/Sources/OpenOats/Views/ContentView.swift` | Deleted in Task 7. Its responsibilities (recording UI, status banners, control bar host) move to `UnifiedOpenOatsView`. |
| `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift` | Replace `Window(id: "main")` and `Window(id: "notes")` with `Window(id: "openoats")` hosting `UnifiedOpenOatsView`. Add `WindowGroup(id: "meeting", for: String.self)`. Update menu commands. |
| `OpenOats/Sources/OpenOats/App/OpenOatsDeepLink.swift` | Update `openNotes(sessionID)` deep-link handler to focus unified window or open pop-out depending on recording state. |
| `OpenOats/Sources/OpenOats/App/MenuBarController.swift` | "Show OpenOats" target updated to `id: "openoats"`. Remove or alias the "Past Meetings" entry. |

---

### Task 1: Extract `NotesSidebarView`

The current `NotesView` is 3,713 lines and intertwines sidebar and detail. This task lifts the sidebar into its own struct so it can be reused by `UnifiedOpenOatsView`.

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/NotesSidebarView.swift`
- Modify: `OpenOats/Sources/OpenOats/Views/NotesView.swift`

**What "the sidebar" includes (bring all of it):**
- The `sidebar(controller:state:)` `@ViewBuilder` method (around `NotesView.swift:191-321`)
- All sidebar-only helpers: `sessionListEntry`, `sessionContextMenu`, `sessionRow`, `folderAssignmentMenu`, `collapsibleFolderSectionHeader`, `collapsibleSourceSectionHeader`, related private helpers (`sessionTitle`, `meetingFamilyPreferences`, `beginRenaming`, `commitRename`, `cancelRename`, `beginCreateFolder`, `commitCreateFolder`, `cancelCreateFolder`)
- Sheet/dialog state owned by sidebar interactions: `renamingSessionID`, `renameDraft`, `creatingFolderForSessionID`, `creatingFolderForMeetingFamilyKey`, `pendingMeetingFamilyFolderChange`, `newFolderDraft`, related @State
- Sheet/dialog views: `renameSessionSheet`, `newFolderSheet`, `meetingFamilyFolderSheet`, `meetingFamilyFolderSheetContent`, `folderEditorSheet`, the meeting-family confirmation dialog

**Step 1: Open NotesView.swift and identify the sidebar block**

Read `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Views/NotesView.swift`. Find the `private func sidebar(controller:state:)` method and the @State properties + helper methods + sheet @ViewBuilders that ONLY drive sidebar interactions (rename, folder, meeting-family folder). Don't take detail-only state (e.g. `confirmRestoreOriginalTranscript`, `showingAddTranscriptSheet`).

- [ ] **Step 2: Create the new file with `NotesSidebarView` skeleton**

Create `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Views/NotesSidebarView.swift`:

```swift
import SwiftUI

/// Sidebar of past meetings: grouped session list, group headers, context
/// menus, and the sheets/dialogs triggered by sidebar interactions
/// (rename, new folder, meeting-family folder editor).
///
/// Extracted from NotesView so both UnifiedOpenOatsView and the (now-removed)
/// NotesView can host the same sidebar UI without duplication.
struct NotesSidebarView: View {
    let controller: NotesController
    let state: NotesState

    // Sheet/dialog state moved from NotesView. These stay @State here because
    // the sheets are triggered by interactions inside this sidebar and the
    // sheets are presented relative to the window, so it's fine for them to
    // attach at this level.
    @State private var renamingSessionID: String?
    @State private var renameDraft: String = ""
    @State private var creatingFolderForSessionID: String?
    @State private var creatingFolderForMeetingFamilyKey: String?
    @State private var pendingMeetingFamilyFolderChange: PendingMeetingFamilyFolderChange?
    @State private var newFolderDraft: String = ""

    var body: some View {
        // TODO: paste the body of NotesView.sidebar(controller:state:) here
        // and attach all sidebar-owned sheets/dialogs.
        EmptyView()
    }

    // TODO: paste sidebar-only @ViewBuilder helpers here:
    // sessionListEntry, sessionContextMenu, sessionRow, folderAssignmentMenu,
    // collapsibleFolderSectionHeader, collapsibleSourceSectionHeader,
    // sessionTitle, plus the sheet view builders:
    // renameSessionSheet, newFolderSheet, meetingFamilyFolderSheet,
    // meetingFamilyFolderSheetContent, folderEditorSheet.

    // TODO: paste private mutating helpers here:
    // beginRenaming, commitRename, cancelRename,
    // beginCreateFolder (both overloads), commitCreateFolder (both overloads),
    // cancelCreateFolder, meetingFamilyPreferences.
}
```

Don't paste the body yet — just create the skeleton with the `// TODO` markers. Step 3 fills it in.

- [ ] **Step 3: Move sidebar code into the new file**

Cut the `private func sidebar(...)` method body from NotesView.swift, all sidebar-only helper methods named in Step 2, the sidebar-only @State, and the sidebar-driven sheet @ViewBuilders, and paste them into `NotesSidebarView.swift` replacing the `// TODO` markers. Remove all `private` qualifiers on the methods (they're inside their own type now) — or keep them private, doesn't matter, the type is the boundary.

The `body` of `NotesSidebarView` becomes what was inside `sidebar(controller:state:)`'s body, with sheets attached:

```swift
var body: some View {
    listBody  // whatever the sidebar's main List is named, currently inside sidebar(...)
        .sheet(
            isPresented: Binding(
                get: { renamingSessionID != nil },
                set: { if !$0 { cancelRename() } }
            )
        ) {
            if let sessionID = renamingSessionID {
                renameSessionSheet(sessionID: sessionID)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { creatingFolderForSessionID != nil },
                set: { if !$0 { cancelCreateFolder() } }
            )
        ) {
            if let sessionID = creatingFolderForSessionID {
                newFolderSheet(sessionID: sessionID)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { creatingFolderForMeetingFamilyKey != nil },
                set: { if !$0 { cancelCreateFolder() } }
            )
        ) {
            meetingFamilyFolderSheetContent()
        }
        .confirmationDialog(
            "Update default folder?",
            isPresented: Binding(
                get: { pendingMeetingFamilyFolderChange != nil },
                set: { if !$0 { pendingMeetingFamilyFolderChange = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingMeetingFamilyFolderChange
        ) { pendingChange in
            Button("Future meetings only") {
                applyPendingMeetingFamilyFolderChange(moveExistingSessions: false)
            }
            Button(moveExistingMeetingsTitle(for: pendingChange)) {
                applyPendingMeetingFamilyFolderChange(moveExistingSessions: true)
            }
            Button("Cancel", role: .cancel) {
                pendingMeetingFamilyFolderChange = nil
            }
        } message: { pendingChange in
            Text(meetingFamilyFolderChangeMessage(for: pendingChange))
        }
}
```

The helper methods that previously took `controller: NotesController` as a parameter can drop the parameter since `controller` is now a stored property — adjust their signatures accordingly.

- [ ] **Step 4: Update `NotesView.swift` to use the new struct**

In `NotesView.swift`, find the `mainLayout(controller:state:)` method (around line 158). Replace the `sidebar(controller: controller, state: state)` call with:

```swift
@ViewBuilder
private func mainLayout(controller: NotesController, state: NotesState) -> some View {
    HStack(spacing: 0) {
        NotesSidebarView(controller: controller, state: state)
            .frame(width: 250)
        Divider()
        detailContent(controller: controller, state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onChange(of: coordinator.lastEndedSession?.id) {
        Task { await controller.handleLastEndedSessionChanged() }
    }
    .onChange(of: coordinator.sessionHistory.count) {
        Task { await controller.loadHistory() }
    }
}
```

Also remove the sheets/state that you moved out of `NotesView` (rename, newFolder, meetingFamilyFolder, related @State, the confirmation dialog for `pendingMeetingFamilyFolderChange`). Keep only the detail-side sheets/state for now (`confirmRestoreOriginalTranscript`, `showingAddTranscriptSheet`) — those move in Task 2.

- [ ] **Step 5: Build and visually verify**

Run: `swift build --package-path OpenOats`
Expected: clean build.

Launch the app (`/Users/jja/Projects/active/openoats/OpenOats/.build/debug/OpenOats`), open the Notes window (⇧⌘M), and verify:
- Past meetings list still renders
- Right-click a session → "Rename" → rename sheet opens, edits work, save closes the sheet
- Right-click a session → "Move to Folder…" → folder sheet works
- Recently-ended session selection works

If any sidebar interaction is broken, fix it in `NotesSidebarView.swift` before continuing.

- [ ] **Step 6: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/NotesSidebarView.swift OpenOats/Sources/OpenOats/Views/NotesView.swift
git commit -m "refactor: extract NotesSidebarView from NotesView"
```

---

### Task 2: Extract `NotesDetailView`

Mirror Task 1 for the detail half of `NotesView`.

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/NotesDetailView.swift`
- Modify: `OpenOats/Sources/OpenOats/Views/NotesView.swift`

**What "the detail" includes:**
- The `detailContent(controller:state:)` `@ViewBuilder` method (around `NotesView.swift:1045`) plus everything it transitively renders
- All detail-only helper @ViewBuilders: notes generation buttons, transcript view embedding, scratchpad section, attachments rendering, error messaging, "no session selected" placeholder
- Detail-side @State: `confirmRestoreOriginalTranscript`, `showingAddTranscriptSheet`, any other state used only by the detail
- Detail-side sheet/dialog views: `addTranscriptSheet`, the restore-transcript confirmation dialog

- [ ] **Step 1: Create the new file with `NotesDetailView` skeleton**

Create `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/Views/NotesDetailView.swift`:

```swift
import SwiftUI

/// Detail content for a selected session: meeting title, notes / transcript /
/// scratchpad / attachments tabs, regenerate buttons, restore-transcript
/// confirmation dialog, add-transcript sheet.
///
/// Extracted from NotesView so both the unified main window and the per-
/// session pop-out window can render the same detail UI.
struct NotesDetailView: View {
    let controller: NotesController
    let state: NotesState

    @State private var confirmRestoreOriginalTranscript: Bool = false
    @State private var showingAddTranscriptSheet: Bool = false

    var body: some View {
        // TODO: paste body of NotesView.detailContent(controller:state:) here
        // and attach detail-owned sheets/dialogs.
        EmptyView()
    }

    // TODO: paste detail-only @ViewBuilder helpers and the addTranscriptSheet
    // sheet view here.
}
```

- [ ] **Step 2: Move detail code into the new file**

Cut `detailContent(controller:state:)` and all detail-only helper @ViewBuilders/private methods from `NotesView.swift`. Paste them into `NotesDetailView.swift`, dropping the `controller:` parameter where helpers had it (use the stored `controller` property instead).

The `body` becomes:

```swift
var body: some View {
    detailRoot
        .confirmationDialog(
            "Restore original transcript?",
            isPresented: $confirmRestoreOriginalTranscript,
            titleVisibility: .visible
        ) {
            Button("Restore Original Transcript") {
                controller.restoreOriginalTranscript()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current transcript with the saved pre-batch version for this session.")
        }
        .sheet(isPresented: $showingAddTranscriptSheet) {
            addTranscriptSheet()
        }
}
```

(Where `detailRoot` is whatever the previous body of `detailContent(...)` rendered.)

- [ ] **Step 3: Update `NotesView.swift` to use the new struct**

In `NotesView.swift`, the `mainLayout(controller:state:)` method becomes:

```swift
@ViewBuilder
private func mainLayout(controller: NotesController, state: NotesState) -> some View {
    HStack(spacing: 0) {
        NotesSidebarView(controller: controller, state: state)
            .frame(width: 250)
        Divider()
        NotesDetailView(controller: controller, state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onChange(of: coordinator.lastEndedSession?.id) {
        Task { await controller.handleLastEndedSessionChanged() }
    }
    .onChange(of: coordinator.sessionHistory.count) {
        Task { await controller.loadHistory() }
    }
}
```

Remove `mainContent(controller:)` if it no longer adds value (its sheets all moved); the body can call `mainLayout` directly.

`NotesView.swift` should now be far smaller — a thin orchestrator that creates the controller and arranges sidebar + detail.

- [ ] **Step 4: Build and visually verify**

Run: `swift build --package-path OpenOats`

Launch the app, open Notes, and verify:
- Selecting a session loads its notes
- "Regenerate Notes" with template picker still works
- "Restore Original Transcript" dialog still appears and works
- "Add Transcript…" sheet still works (if reachable)
- Notes generation streaming still updates the view
- Scratchpad and attachments still render

- [ ] **Step 5: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/NotesDetailView.swift OpenOats/Sources/OpenOats/Views/NotesView.swift
git commit -m "refactor: extract NotesDetailView from NotesView"
```

---

### Task 3: `PastMeetingViewModel`

A session-scoped, observable view model that loads one session's data and exposes regeneration. Smaller and simpler than `NotesController` (no session list, no folders, no navigation).

**Files:**
- Create: `OpenOats/Sources/OpenOats/App/PastMeetingViewModel.swift`
- Create: `OpenOats/Tests/OpenOatsTests/PastMeetingViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `/Users/jja/Projects/active/openoats/OpenOats/Tests/OpenOatsTests/PastMeetingViewModelTests.swift`:

```swift
import XCTest
@testable import OpenOatsKit

@MainActor
final class PastMeetingViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDirs() -> (root: URL, notes: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OpenOatsPastMeetingVMTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesDirectory = root.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        return (root, notesDirectory)
    }

    private func makeCoordinator(root: URL) -> AppCoordinator {
        AppCoordinator(
            sessionRepository: SessionRepository(rootDirectory: root),
            templateStore: TemplateStore(rootDirectory: root),
            notesEngine: NotesEngine(mode: .scripted(markdown: "# Test\n\nGenerated body.")),
            transcriptStore: TranscriptStore()
        )
    }

    // MARK: - Tests

    func testLoadsSessionFromRepository() async {
        let (root, _) = makeTempDirs()
        let coordinator = makeCoordinator(root: root)
        let sessionID = "session_test_load"
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            SessionRecord(speaker: .you, text: "Hello.", timestamp: startedAt),
            SessionRecord(speaker: .them, text: "Hi.", timestamp: startedAt.addingTimeInterval(5)),
        ]

        await coordinator.sessionRepository.seedSession(
            id: sessionID,
            records: records,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            templateSnapshot: coordinator.templateStore.snapshot(
                of: coordinator.templateStore.template(for: TemplateStore.genericID) ?? TemplateStore.builtInTemplates.first!
            ),
            title: "Loaded Meeting"
        )

        let viewModel = PastMeetingViewModel(coordinator: coordinator, sessionID: sessionID)
        await viewModel.load()

        XCTAssertEqual(viewModel.sessionTitle, "Loaded Meeting")
        XCTAssertEqual(viewModel.transcript.count, 2)
        XCTAssertNil(viewModel.error)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path OpenOats --filter PastMeetingViewModelTests/testLoadsSessionFromRepository`
Expected: FAIL with "cannot find 'PastMeetingViewModel' in scope".

- [ ] **Step 3: Implement `PastMeetingViewModel`**

Create `/Users/jja/Projects/active/openoats/OpenOats/Sources/OpenOats/App/PastMeetingViewModel.swift`:

```swift
import Foundation
import Observation

/// Session-scoped view model owned by `PastMeetingWindowView`. Loads one
/// past session's records, notes, and scratchpad from `SessionRepository`,
/// triggers regeneration via the shared `NotesEngine`, and observes the
/// repository so changes from other windows (e.g. notes regenerated in the
/// unified window) reflect here automatically.
@Observable
@MainActor
final class PastMeetingViewModel {
    @ObservationIgnored nonisolated(unsafe) private var _sessionTitle: String = ""
    private(set) var sessionTitle: String {
        get { access(keyPath: \.sessionTitle); return _sessionTitle }
        set { withMutation(keyPath: \.sessionTitle) { _sessionTitle = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _transcript: [SessionRecord] = []
    private(set) var transcript: [SessionRecord] {
        get { access(keyPath: \.transcript); return _transcript }
        set { withMutation(keyPath: \.transcript) { _transcript = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _notes: GeneratedNotes?
    private(set) var notes: GeneratedNotes? {
        get { access(keyPath: \.notes); return _notes }
        set { withMutation(keyPath: \.notes) { _notes = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _scratchpad: String = ""
    private(set) var scratchpad: String {
        get { access(keyPath: \.scratchpad); return _scratchpad }
        set { withMutation(keyPath: \.scratchpad) { _scratchpad = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _isGenerating: Bool = false
    private(set) var isGenerating: Bool {
        get { access(keyPath: \.isGenerating); return _isGenerating }
        set { withMutation(keyPath: \.isGenerating) { _isGenerating = newValue } }
    }

    @ObservationIgnored nonisolated(unsafe) private var _error: String?
    private(set) var error: String? {
        get { access(keyPath: \.error); return _error }
        set { withMutation(keyPath: \.error) { _error = newValue } }
    }

    let sessionID: String
    private let coordinator: AppCoordinator
    private var observationTask: Task<Void, Never>?

    init(coordinator: AppCoordinator, sessionID: String) {
        self.coordinator = coordinator
        self.sessionID = sessionID
    }

    deinit {
        observationTask?.cancel()
    }

    /// Loads the session's data from the repository. Call once when the view
    /// appears.
    func load() async {
        let session = coordinator.sessionHistory.first { $0.id == sessionID }
        sessionTitle = session?.title ?? "Untitled meeting"

        let records = await coordinator.sessionRepository.loadTranscript(sessionID: sessionID)
        transcript = records

        let loadedNotes = await coordinator.sessionRepository.loadNotes(sessionID: sessionID)
        notes = loadedNotes

        let pad = await coordinator.sessionRepository.loadScratchpad(sessionID: sessionID)
        scratchpad = pad
    }

    /// Regenerates notes for this session via the shared `NotesEngine`.
    func regenerateNotes(settings: AppSettings, template: MeetingTemplate) {
        guard !isGenerating else { return }
        isGenerating = true
        error = nil

        Task {
            let scratchpadValue = await coordinator.sessionRepository.loadScratchpad(sessionID: sessionID)
            coordinator.notesEngine.generate(
                transcript: transcript,
                template: template,
                settings: settings,
                scratchpad: scratchpadValue.isEmpty ? nil : scratchpadValue
            ) { [weak self] in
                guard let self else { return }
                Task { await self.finishGeneration(template: template) }
            }
        }
    }

    private func finishGeneration(template: MeetingTemplate) async {
        defer { isGenerating = false }

        let generated = coordinator.notesEngine.generatedMarkdown
        if generated.isEmpty {
            if let engineError = coordinator.notesEngine.error {
                error = engineError
            }
            return
        }

        let session = coordinator.sessionHistory.first { $0.id == sessionID }
        let heading = NotesController.notesHeading(title: session?.title, date: session?.startedAt ?? Date())
        let markdown = heading + generated
        let saved = GeneratedNotes(
            template: coordinator.templateStore.snapshot(of: template),
            generatedAt: Date(),
            markdown: markdown
        )
        await coordinator.sessionRepository.saveNotes(sessionID: sessionID, notes: saved)
        notes = saved
        await coordinator.loadHistory()
    }
}
```

If `NotesController.notesHeading(title:date:)` is `private` in the existing `NotesController`, expose it as `static internal` in `NotesController.swift` (one-line visibility change). Adjust if the actual signature differs.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path OpenOats --filter PastMeetingViewModelTests/testLoadsSessionFromRepository`
Expected: PASS.

If the test fails because `SessionRepository.seedSession` or `loadTranscript` signatures differ, adapt the test/VM to match the actual repo API (cross-reference `OpenOats/Tests/OpenOatsTests/NotesControllerTests.swift` for the seeding pattern in use).

- [ ] **Step 5: Add a regeneration test**

Append to `PastMeetingViewModelTests.swift`:

```swift
func testRegenerateNotesUpdatesViewModel() async {
    let (root, _) = makeTempDirs()
    let coordinator = makeCoordinator(root: root)
    let sessionID = "session_test_regen"
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    await coordinator.sessionRepository.seedSession(
        id: sessionID,
        records: [SessionRecord(speaker: .you, text: "Hi.", timestamp: startedAt)],
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(60),
        templateSnapshot: coordinator.templateStore.snapshot(
            of: coordinator.templateStore.template(for: TemplateStore.genericID) ?? TemplateStore.builtInTemplates.first!
        ),
        title: "Regen Meeting"
    )

    let viewModel = PastMeetingViewModel(coordinator: coordinator, sessionID: sessionID)
    await viewModel.load()

    let suiteName = "com.openoats.tests.pastmeeting.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    let storage = SettingsStorage(
        defaults: defaults,
        secretStore: .ephemeral,
        defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
        runMigrations: false
    )
    let settings = AppSettings(storage: storage)
    let template = TemplateStore.builtInTemplates.first!

    viewModel.regenerateNotes(settings: settings, template: template)
    // Scripted NotesEngine completes synchronously inside its Task, so a
    // short sleep is enough.
    try? await Task.sleep(for: .milliseconds(500))

    XCTAssertNotNil(viewModel.notes)
    XCTAssertTrue(viewModel.notes?.markdown.contains("Generated body.") ?? false)
    XCTAssertFalse(viewModel.isGenerating)
}
```

- [ ] **Step 6: Run regen test**

Run: `swift test --package-path OpenOats --filter PastMeetingViewModelTests`
Expected: 2/2 pass.

- [ ] **Step 7: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/PastMeetingViewModel.swift OpenOats/Tests/OpenOatsTests/PastMeetingViewModelTests.swift OpenOats/Sources/OpenOats/App/NotesController.swift
git commit -m "feat: add PastMeetingViewModel for per-session pop-out windows"
```

---

### Task 4: `PastMeetingWindowView`

The pop-out window's root view. Composes `PastMeetingViewModel` with the `NotesDetailView` extracted in Task 2.

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/PastMeetingWindowView.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

/// Root view for a per-session pop-out window. Loads its data via a
/// session-scoped `PastMeetingViewModel` and renders the same detail UI as
/// the unified window's right pane (no sidebar, no control bar).
struct PastMeetingWindowView: View {
    let sessionID: String
    let settings: AppSettings

    @Environment(AppCoordinator.self) private var coordinator
    @State private var viewModel: PastMeetingViewModel?

    var body: some View {
        Group {
            if let viewModel {
                // NotesDetailView currently expects a NotesController + NotesState.
                // We adapt: a `PastMeetingDetailAdapter` wraps the view model with
                // the surface NotesDetailView reads. Alternatively, NotesDetailView
                // grows a second initializer that takes a PastMeetingViewModel
                // directly. Pick whichever is less invasive at implementation time.
                PastMeetingDetailHost(viewModel: viewModel, settings: settings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(viewModel?.sessionTitle ?? "Past Meeting")
        .task {
            let vm = PastMeetingViewModel(coordinator: coordinator, sessionID: sessionID)
            viewModel = vm
            await vm.load()
        }
    }
}

/// Bridges `PastMeetingViewModel` to the same content `NotesDetailView`
/// renders. If `NotesDetailView` is parameterized to accept either a
/// `NotesController` or a `PastMeetingViewModel`, prefer that direct path
/// over a host wrapper.
private struct PastMeetingDetailHost: View {
    let viewModel: PastMeetingViewModel
    let settings: AppSettings

    var body: some View {
        // Implementation choice: in Task 2 we extracted NotesDetailView with
        // a `controller: NotesController` dependency. The simplest path here
        // is to add a second initializer or a content-mode parameter to
        // NotesDetailView so it can render from a PastMeetingViewModel
        // without the controller's session-list responsibilities.
        //
        // For now, render a minimal viewer that proves the wiring (notes
        // markdown + transcript text). We swap in NotesDetailView in the
        // post-extraction polish pass.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(viewModel.sessionTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                if let notes = viewModel.notes {
                    Text(notes.markdown)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No notes generated yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}
```

The `PastMeetingDetailHost` placeholder is intentional — it proves the window plumbing without blocking on `NotesDetailView`'s second-init refactor. Step 2 of Task 7 (UnifiedOpenOatsView assembly) revisits this so both windows render the full detail UI from a common path.

- [ ] **Step 2: Build**

Run: `swift build --package-path OpenOats`
Expected: clean build (no callers of the new view yet).

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/PastMeetingWindowView.swift
git commit -m "feat: add PastMeetingWindowView for per-session pop-out"
```

---

### Task 5: Add `WindowGroup` scene + open-window plumbing

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift`

- [ ] **Step 1: Add the `WindowGroup` scene**

In `OpenOatsApp.swift`, find the existing scene declarations (around `OpenOatsApp.swift:35-146`) and add a new scene next to the Transcript window:

```swift
WindowGroup("Past Meeting", id: "meeting", for: String.self) { $sessionID in
    if let id = sessionID {
        PastMeetingWindowView(sessionID: id, settings: settings)
            .environment(container)
            .environment(coordinator)
            .defaultAppStorage(defaults)
    }
}
.defaultSize(width: 720, height: 700)
```

(Place it immediately before `Settings { … }`.)

- [ ] **Step 2: Add the `Open Selected in New Window` menu command (no implementation yet)**

In the `.commands { CommandGroup(after: .appInfo) { … } }` block, add:

```swift
Button("Open Selected in New Window") {
    coordinator.requestOpenSelectedInNewWindow()
}
.keyboardShortcut("o", modifiers: [.command, .shift])
.disabled(coordinator.selectedSessionIDForNewWindow == nil)
```

The methods `requestOpenSelectedInNewWindow()` and `selectedSessionIDForNewWindow` will be implemented in Task 8 (the unified-window task) where we know which session is selected. For now, declare them as stubs on `AppCoordinator`:

In `AppCoordinator.swift`, add:

```swift
// Set by UnifiedOpenOatsView when the sidebar selection changes. Read by
// the menu command to decide whether to enable "Open Selected in New Window".
@ObservationIgnored nonisolated(unsafe) private var _selectedSessionIDForNewWindow: String?
nonisolated var selectedSessionIDForNewWindow: String? {
    get { _selectedSessionIDForNewWindow }
    set { _selectedSessionIDForNewWindow = newValue }
}

/// Closure set by `UnifiedOpenOatsView` to handle the menu command.
@MainActor var openSelectedInNewWindowAction: (() -> Void)?

@MainActor
func requestOpenSelectedInNewWindow() {
    openSelectedInNewWindowAction?()
}
```

- [ ] **Step 3: Build**

Run: `swift build --package-path OpenOats`
Expected: clean build (the menu command compiles even though no view sets `openSelectedInNewWindowAction` yet — it just no-ops).

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/OpenOatsApp.swift OpenOats/Sources/OpenOats/App/AppCoordinator.swift
git commit -m "feat: add Past Meeting WindowGroup scene and Open Selected menu command"
```

---

### Task 6: `UnifiedOpenOatsView`

The unified window's root view. Hosts the sidebar, the state-machine detail area, and the persistent control bar.

**Files:**
- Create: `OpenOats/Sources/OpenOats/Views/UnifiedOpenOatsView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// Root view of the unified OpenOats window. Lays out:
///   ┌──────────────┬───────────────────────────┐
///   │              │   Detail (recording or    │
///   │   Sidebar    │   selected past meeting   │
///   │              │   or empty state)         │
///   ├──────────────┴───────────────────────────┤
///   │             ControlBar                   │
///   └──────────────────────────────────────────┘
struct UnifiedOpenOatsView: View {
    @Bindable var settings: AppSettings

    @Environment(AppContainer.self) private var container
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(FocusedPaneStore.self) private var focusedPane
    @Environment(\.openWindow) private var openWindow

    @State private var notesController: NotesController?

    var body: some View {
        Group {
            if let controller = notesController {
                ready(controller: controller)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if coordinator.knowledgeBase == nil {
                container.ensureViewServicesInitialized(settings: settings, coordinator: coordinator)
            }
            let controller = NotesController(coordinator: coordinator, settings: settings)
            notesController = controller
            await controller.loadHistory()

            // Wire the menu-command hook so ⇧⌘O / "Open Selected in New
            // Window" pops the currently selected session.
            coordinator.openSelectedInNewWindowAction = { [weak controller] in
                guard let controller else { return }
                if let id = controller.state.selectedSessionID {
                    openWindow(id: "meeting", value: id)
                }
            }
        }
        .onDisappear {
            coordinator.openSelectedInNewWindowAction = nil
        }
    }

    @ViewBuilder
    private func ready(controller: NotesController) -> some View {
        let liveState = coordinator.liveSessionController?.state
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NotesSidebarView(controller: controller, state: controller.state)
                    .frame(width: 250)
                    .onChange(of: controller.state.selectedSessionID) { _, newValue in
                        coordinator.selectedSessionIDForNewWindow = newValue
                    }
                Divider()
                detailArea(controller: controller, liveState: liveState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            controlBar(liveState: liveState)
        }
        .onChange(of: liveState?.isRunning ?? false) { _, isRunning in
            if isRunning {
                // Recording started — clear sidebar selection so the right
                // pane is unambiguously the live session.
                controller.selectSession(nil)
            } else if let lastEnded = coordinator.lastEndedSession?.id {
                // Recording ended — auto-select the just-ended session.
                controller.selectSession(lastEnded)
            }
        }
    }

    @ViewBuilder
    private func detailArea(controller: NotesController, liveState: LiveSessionState?) -> some View {
        if let liveState, liveState.isRunning {
            recordingArea(liveState: liveState)
        } else if controller.state.selectedSessionID != nil {
            // Show the past-meeting detail. Wrap intercept clicks so that
            // single-click on a different sidebar row pops a new window
            // when recording — handled inside the sidebar itself.
            NotesDetailView(controller: controller, state: controller.state)
        } else {
            idleEmptyState
        }
    }

    @ViewBuilder
    private func recordingArea(liveState: LiveSessionState) -> some View {
        VStack(spacing: 0) {
            StackedPanesView(
                controllerState: liveState,
                settings: settings,
                focusedPane: focusedPane
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if liveState.isRunning {
                Divider()
                ScratchpadSection(
                    text: Binding(
                        get: { liveState.scratchpadText },
                        set: { coordinator.liveSessionController?.updateScratchpad($0) }
                    ),
                    onPasteAssetProviders: { _ in /* paste handler set up in Task 7 polish */ }
                )
            }
        }
    }

    private var idleEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Start a new meeting from below, or pick a past one from the sidebar.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func controlBar(liveState: LiveSessionState?) -> some View {
        // Reuse ControlBar with the same parameter shape it expects today.
        // Concrete callbacks are wired the same way ContentView did them.
        ControlBar(
            isRunning: liveState?.isRunning ?? false,
            audioLevel: liveState?.audioLevel ?? 0,
            isMicMuted: liveState?.isMicMuted ?? false,
            isRecordingPaused: false, // adjust to match upstream's actual ControlBar signature
            recordingElapsedSeconds: liveState?.recordingElapsedSeconds ?? 0,
            modelDisplayName: liveState?.modelDisplayName ?? "",
            transcriptionPrompt: liveState?.transcriptionPrompt ?? "",
            statusMessage: liveState?.statusMessage,
            errorMessage: liveState?.errorMessage,
            needsDownload: liveState?.needsDownload ?? false,
            downloadProgress: liveState?.downloadProgress,
            downloadDetail: liveState?.downloadDetail,
            onToggle: { coordinator.liveSessionController?.toggleRecording(settings: settings) },
            onMuteToggle: { coordinator.liveSessionController?.toggleMicMute() },
            onPauseToggle: { coordinator.liveSessionController?.toggleRecordingPause() },
            onConfirmDownload: { coordinator.liveSessionController?.confirmDownload(settings: settings) }
        )
    }
}
```

The `ControlBar` initializer above mirrors what the post-merge `ContentView.swift` passes today (lines 227-247). Open `OpenOats/Sources/OpenOats/Views/ContentView.swift` to confirm the exact parameter list and copy it verbatim — Swift will tell you if anything is misnamed. Likewise the `ScratchpadSection` initializer's actual paste callback should match what `ContentView.handleScratchpadAssetPaste(_:)` does; punt the copy for now and revisit in Task 7's polish step.

The sidebar's "single-click during recording opens new window" behavior needs help from `NotesSidebarView`. Add to the sidebar a `@Environment(\.openWindow) private var openWindow` and check `coordinator.liveSessionController?.state.isRunning ?? false` inside the row's tap handler. If recording, call `openWindow(id: "meeting", value: session.id)` instead of `controller.selectSession(session.id)`. Make this change in `NotesSidebarView.swift` as part of this task (it's the natural place).

- [ ] **Step 2: Build**

Run: `swift build --package-path OpenOats`
Expected: clean build. Errors here usually mean `ControlBar` parameter mismatches — fix by matching the actual `ControlBar` signature in `ControlBar.swift`.

- [ ] **Step 3: Commit**

```bash
git add OpenOats/Sources/OpenOats/Views/UnifiedOpenOatsView.swift OpenOats/Sources/OpenOats/Views/NotesSidebarView.swift
git commit -m "feat: add UnifiedOpenOatsView with sidebar + state-machine detail + control bar"
```

---

### Task 7: Wire unified scene; remove old `main` and `notes` scenes

This is the cutover. After this task, the app launches into the unified window only.

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift`
- Delete: `OpenOats/Sources/OpenOats/Views/ContentView.swift`
- Delete: `OpenOats/Sources/OpenOats/Views/NotesView.swift`

- [ ] **Step 1: Replace the `main` and `notes` scenes**

In `OpenOatsApp.swift`, replace the `Window("OpenOats", id: "main")` block and the `Window("Notes", id: "notes")` block with a single:

```swift
Window("OpenOats", id: "openoats") {
    UnifiedOpenOatsView(settings: settings)
        .environment(container)
        .environment(coordinator)
        .environment(focusedPane)
        .defaultAppStorage(defaults)
        .onAppear {
            appDelegate.configure(
                coordinator: coordinator,
                settings: settings,
                defaults: defaults,
                container: container,
                showMainWindow: { [self] in showMainWindow() },
                checkForUpdates: { updaterController.checkForUpdatesFromMenuBar() }
            )
            DiagnosticsSupport.record(category: "app", message: "Unified window appeared")
            settings.applyScreenShareVisibility()
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
}
.windowStyle(.hiddenTitleBar)
.windowResizability(.contentMinSize)
.defaultSize(width: 1100, height: 700)
```

Where `handleDeepLink(url)` is a private helper that contains the same body as the old `.onOpenURL` handler. Bumped default size from 720×560 to 1100×700 because the unified window now has both sidebar and detail.

Update `Self.mainWindowID` to `"openoats"`.

- [ ] **Step 2: Update the "Past Meetings" menu command**

In the same file, the `Button("Past Meetings") { openNotesWindow() }` becomes:

```swift
Button("Past Meetings") {
    showMainWindow()
}
.keyboardShortcut("m", modifiers: [.command, .shift])
```

Remove `openNotesWindow()` from the file (or repurpose it to call `showMainWindow()`). The `appDelegate.configure(... showMainWindow: ...)` callback still wires up to the unified window.

- [ ] **Step 3: Delete `ContentView.swift` and `NotesView.swift`**

```bash
rm OpenOats/Sources/OpenOats/Views/ContentView.swift
rm OpenOats/Sources/OpenOats/Views/NotesView.swift
```

If `ContentView` had helpers used elsewhere, move them into `UnifiedOpenOatsView.swift` or a new `Views/ContentHelpers.swift`. Likely candidates: `IsolatedControlBarWrapper`, `IsolatedSetupWizardWrapper`, `WindowChromeTopInsetReader` (if you re-introduce it), `loadPastedScratchpadAssets`. Run `swift build --package-path OpenOats` and follow the error messages — each missing symbol points at where it needs to live.

- [ ] **Step 4: Build the package**

Run: `swift build --package-path OpenOats`

Iterate on errors until the build is clean. Common fixes:
- Missing `IsolatedControlBarWrapper`: move it into `UnifiedOpenOatsView.swift` or the new helpers file.
- Missing `loadPastedScratchpadAssets`: same.
- Missing `copyTranscript()`: replace call sites with `TranscriptClipboard.copy(_:)` (added in commit `ed1dc65`).

- [ ] **Step 5: Build tests too**

Run: `swift build --package-path OpenOats --build-tests`

UI smoke tests (under `UITests/`) may reference window IDs. Update any `main` references to `openoats`. Update any `notes` references to `openoats` as well — the sidebar is now part of the same window. If a UI test was specifically opening the Notes window with `⇧⌘M`, it should now work the same way (the shortcut still focuses the sidebar in the unified window).

- [ ] **Step 6: Run the full test suite**

Run: `swift test --package-path OpenOats`
Expected: all unit tests pass (`LiveSummaryEngineTests`, `LiveSessionControllerTests`, `NotesControllerTests`, `PastMeetingViewModelTests`, etc.).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: unify main and Notes windows into single OpenOats window"
```

---

### Task 8: Deep links, menu bar, manual QA prep

**Files:**
- Modify: `OpenOats/Sources/OpenOats/App/OpenOatsDeepLink.swift`
- Modify: `OpenOats/Sources/OpenOats/App/MenuBarController.swift`
- Modify: `OpenOats/Sources/OpenOats/App/OpenOatsApp.swift` (`handleDeepLink`)

- [ ] **Step 1: Update the `openNotes(sessionID)` deep-link handler**

In `OpenOatsApp.swift`'s `handleDeepLink(url)` (or wherever the deep-link case is handled), replace the `case .openNotes(let sessionID)` body with:

```swift
case .openNotes(let sessionID):
    coordinator.queueSessionSelection(sessionID)
    if coordinator.liveSessionController?.state.isRunning == true {
        // Recording in progress — pop the requested meeting into its own
        // window so the live recording UI stays put.
        openWindow(id: "meeting", value: sessionID)
    } else {
        showMainWindow()
    }
```

Remove `openNotesWindow()` entirely — it has no remaining callers.

- [ ] **Step 2: Update `MenuBarController.swift`**

Find the menu bar popover's "Show OpenOats" entry (or equivalent) and confirm it calls `showMainWindow()` (which now opens `id: "openoats"`). If there's a separate "Past Meetings" entry, remove it (or alias it to "Show OpenOats").

- [ ] **Step 3: Build**

Run: `swift build --package-path OpenOats`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add OpenOats/Sources/OpenOats/App/OpenOatsApp.swift OpenOats/Sources/OpenOats/App/MenuBarController.swift OpenOats/Sources/OpenOats/App/OpenOatsDeepLink.swift
git commit -m "feat: route deep links and menu bar to unified OpenOats window"
```

---

### Task 9: Manual QA

No code changes — this is the validation pass against the spec's success criteria.

- [ ] **Step 1: Launch debug binary**

```bash
/Users/jja/Projects/active/openoats/OpenOats/.build/debug/OpenOats
```

Confirm `BuildInfo` shows the new build date (today). The unified window opens with sidebar + empty state + control bar.

- [ ] **Step 2: Sidebar interactions**

- Past meetings list renders.
- Single-click a past meeting (idle state) → loads in detail pane.
- Right-click → "Rename" → sheet works.
- Right-click → "Move to Folder…" → sheet works.
- ⌘-click on a session → opens that session in a new Past Meeting window.
- Right-click → "Open in New Window" → opens in a new window.

- [ ] **Step 3: Recording while idle**

- Click "Start" in the control bar → recording begins; right pane swaps to `StackedPanesView` + scratchpad; sidebar selection clears.
- Detail slider works in the Summary pane (validates Task 7 from the previous plan).
- Recording timer ticks up.
- Click a past meeting in the sidebar while recording → opens new Past Meeting window automatically.
- Click "Stop" → sidebar auto-selects the just-ended session; detail swaps to its notes view; "Generating notes…" spinner appears until generation completes.

- [ ] **Step 4: Multi-window**

- Open three different past meetings, each in its own pop-out window.
- Confirm Window menu lists all of them by title.
- Close one — the others stay open.
- Regenerate notes from a pop-out → confirm the unified window's sidebar badge updates.

- [ ] **Step 5: Menu and shortcuts**

- ⇧⌘L toggles meeting (start/stop).
- ⇧⌘M brings unified window forward and focuses sidebar.
- ⇧⌘O opens currently-selected session in a new window (disabled when nothing selected).
- ⌘= / ⌘- / ⌘0 zoom panes.

- [ ] **Step 6: Deep links**

Trigger `openoats://notes/<id>` from Terminal:

```bash
open "openoats://notes/<known-session-id>"
```

- While idle: brings unified window forward, selects that session.
- While recording: opens the session in a new Past Meeting window (recording UI stays put in the unified window).

- [ ] **Step 7: Window restoration**

- Quit the app and relaunch. Unified window restores at its previous size/position. (Past Meeting pop-outs are not expected to restore — see spec's Risks section.)

- [ ] **Step 8: Commit any cleanup tweaks**

If manual QA surfaces fixable nits (typography, missing `accessibilityIdentifier`s, etc.), commit them as a small polish commit:

```bash
git add <files>
git commit -m "polish: unified window manual-QA tweaks"
```

---

## Self-Review Checklist

- [ ] Every spec section maps to a task
- [ ] No "TBD" / "TODO" / "implement later" / "fill in details" anywhere
- [ ] Type names consistent across tasks: `NotesSidebarView`, `NotesDetailView`, `PastMeetingViewModel`, `PastMeetingWindowView`, `UnifiedOpenOatsView`; window IDs `openoats` and `meeting`
- [ ] Test file path consistent: `OpenOats/Tests/OpenOatsTests/PastMeetingViewModelTests.swift`
- [ ] Build/test commands all use `--package-path OpenOats`
- [ ] Deletes called out explicitly (`ContentView.swift`, `NotesView.swift`) so the engineer doesn't leave them lying around
