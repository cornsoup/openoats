import XCTest
@testable import OpenOatsKit

@MainActor
final class LiveSummaryEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeSettings() -> AppSettings {
        let suiteName = "com.openoats.tests.livesummary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let storage = SettingsStorage(
            defaults: defaults,
            secretStore: .ephemeral,
            defaultNotesDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            runMigrations: false
        )
        let settings = AppSettings(storage: storage)
        // Set an in-memory API key so hasValidCredentials returns true.
        // (The .ephemeral secretStore doesn't persist, but the in-memory _openRouterApiKey is set by the setter.)
        settings.openRouterApiKey = "dummy-key"
        return settings
    }

    private func makeEngine(responses: [String]) -> LiveSummaryEngine {
        LiveSummaryEngine(settings: makeSettings(), mode: .scripted(responses: responses))
    }

    /// Builds a batch of 6 utterances (threshold to trigger an update).
    /// Utterance init signature: `Utterance(text:speaker:timestamp:)` — see Utterance.swift:80.
    private func sixUtterances() -> [Utterance] {
        (0..<6).map { i in
            Utterance(
                text: "utterance \(i)",
                speaker: i % 2 == 0 ? .you : .them,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i))
            )
        }
    }

    private func waitForEngineIdle(_ engine: LiveSummaryEngine, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.isGenerating && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Allow one more tick for the deferred @MainActor Task that resets isGenerating and updateTask.
        try? await Task.sleep(for: .milliseconds(50))
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
