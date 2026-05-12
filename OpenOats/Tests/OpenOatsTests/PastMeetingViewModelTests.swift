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
        await coordinator.loadHistory()

        let viewModel = PastMeetingViewModel(coordinator: coordinator, sessionID: sessionID)
        await viewModel.load()

        XCTAssertEqual(viewModel.sessionTitle, "Loaded Meeting")
        XCTAssertEqual(viewModel.transcript.count, 2)
        XCTAssertNil(viewModel.error)
    }

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
        await coordinator.loadHistory()

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
}
