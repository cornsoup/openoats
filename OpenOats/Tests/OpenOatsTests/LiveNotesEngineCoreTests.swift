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
        let u = Utterance(text: "hello", speaker: .you,
                          timestamp: Date(timeIntervalSince1970: 100),
                          cleanedText: "Hello.", cleanupStatus: nil)
        let records = LiveNotesEngine.records(from: [u])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].text, "hello")
        XCTAssertEqual(records[0].cleanedText, "Hello.")
        XCTAssertEqual(records[0].timestamp, Date(timeIntervalSince1970: 100))
    }
}
