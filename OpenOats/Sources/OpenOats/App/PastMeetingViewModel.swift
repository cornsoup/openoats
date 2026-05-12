import Foundation
import Observation

/// Session-scoped view model owned by `PastMeetingWindowView` (added in Task 4).
/// Loads one past session's records, notes, and scratchpad from
/// `SessionRepository` and triggers regeneration via the shared `NotesEngine`.
///
/// Cross-window observation is NOT yet implemented — if the user regenerates
/// notes in the unified window while a pop-out for the same session is open,
/// the pop-out will show stale data until manually reloaded. Tracked as a
/// v1.5 follow-up.
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

    init(coordinator: AppCoordinator, sessionID: String) {
        self.coordinator = coordinator
        self.sessionID = sessionID
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
    ///
    /// Note: `notesEngine` is shared with `NotesController` (the unified
    /// window's controller). If both call `generate(...)` concurrently, the
    /// second call cancels the first and we'd read its result. For v1 we
    /// rely on the user not triggering both at once.
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
                Task { @MainActor in await self.finishGeneration(template: template) }
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
        let markdown = NotesController.normalizedNotesMarkdown(
            generated,
            title: session?.title,
            date: session?.startedAt ?? Date()
        )
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
