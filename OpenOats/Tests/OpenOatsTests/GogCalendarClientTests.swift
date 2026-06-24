import XCTest
@testable import OpenOatsKit

final class GogCalendarClientTests: XCTestCase {

    // A bare JSON array, matching `gog calendar events -j --results-only`.
    private let sampleJSON = """
    [
      {
        "id": "evt1",
        "summary": "On-site Meeting with Hilary",
        "status": "confirmed",
        "start": { "dateTime": "2026-06-25T13:00:00-07:00", "timeZone": "America/Los_Angeles" },
        "end":   { "dateTime": "2026-06-25T14:00:00-07:00", "timeZone": "America/Los_Angeles" },
        "organizer": { "email": "scheduling@rockbaycnr.com" },
        "attendees": [
          { "email": "jja@cornsoup.net", "self": true },
          { "email": "hilfin@gmail.com" }
        ],
        "hangoutLink": "https://meet.google.com/ros-bvwe-jiq",
        "location": "Menlo Park, CA"
      },
      {
        "id": "allday",
        "summary": "Vacation",
        "status": "confirmed",
        "start": { "date": "2026-06-25" },
        "end":   { "date": "2026-06-26" }
      },
      {
        "id": "cancelledEvt",
        "summary": "Cancelled Standup",
        "status": "cancelled",
        "start": { "dateTime": "2026-06-25T13:30:00-07:00" },
        "end":   { "dateTime": "2026-06-25T13:45:00-07:00" }
      }
    ]
    """

    func testDecodesTimedEventAndExcludesAllDayAndCancelled() {
        let events = GogCalendarClient.events(fromJSON: Data(sampleJSON.utf8))
        XCTAssertEqual(events.count, 1)
        let e = events[0]
        XCTAssertEqual(e.id, "evt1")
        XCTAssertEqual(e.title, "On-site Meeting with Hilary")
        XCTAssertEqual(e.organizer, "scheduling@rockbaycnr.com")
        XCTAssertEqual(e.participants.count, 2)
        XCTAssertEqual(e.participants.first?.email, "jja@cornsoup.net")
        XCTAssertTrue(e.isOnlineMeeting)
        XCTAssertEqual(e.meetingURL?.absoluteString, "https://meet.google.com/ros-bvwe-jiq")
    }

    func testParsesStartEndDates() {
        let events = GogCalendarClient.events(fromJSON: Data(sampleJSON.utf8))
        // 2026-06-25T13:00:00-07:00 == 2026-06-25T20:00:00Z
        let expectedStart = ISO8601DateFormatter().date(from: "2026-06-25T20:00:00Z")
        XCTAssertEqual(events.first?.startDate, expectedStart)
    }

    func testDecodesEnvelopeShape() {
        let envelope = #"{ "events": [ { "id": "x", "summary": "Wrapped", "status": "confirmed", "start": { "dateTime": "2026-06-25T13:00:00-07:00" }, "end": { "dateTime": "2026-06-25T14:00:00-07:00" } } ] }"#
        let events = GogCalendarClient.events(fromJSON: Data(envelope.utf8))
        XCTAssertEqual(events.map(\.id), ["x"])
    }

    func testGarbageReturnsEmpty() {
        XCTAssertEqual(GogCalendarClient.events(fromJSON: Data("not json".utf8)).count, 0)
        XCTAssertEqual(GogCalendarClient.events(fromJSON: Data()).count, 0)
    }
}
