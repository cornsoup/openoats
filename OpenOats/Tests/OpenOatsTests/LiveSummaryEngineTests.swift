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
        XCTAssertTrue(engine.keyPointsItems.isEmpty, "newItems: {} should leave item lists empty")
    }

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
