import XCTest
@testable import OpenOatsKit

final class CalendarEventSelectionTests: XCTestCase {

    private func event(id: String, start: Date, end: Date) -> CalendarEvent {
        CalendarEvent(
            id: id, title: id, startDate: start, endDate: end,
            organizer: nil, participants: [], isOnlineMeeting: false, meetingURL: nil
        )
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(CalendarEventSelection.bestOverlap(events: [], at: Date()))
    }

    func testPicksClosestStartToDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let near = event(id: "near", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(600))
        let far = event(id: "far", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600))
        let best = CalendarEventSelection.bestOverlap(events: [far, near], at: now)
        XCTAssertEqual(best?.id, "near")
    }

    func testTieBreaksOnEarlierStart() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Both equidistant (±120s); earlier start should win.
        let earlier = event(id: "earlier", start: now.addingTimeInterval(-120), end: now)
        let later = event(id: "later", start: now.addingTimeInterval(120), end: now.addingTimeInterval(600))
        let best = CalendarEventSelection.bestOverlap(events: [later, earlier], at: now)
        XCTAssertEqual(best?.id, "earlier")
    }
}
