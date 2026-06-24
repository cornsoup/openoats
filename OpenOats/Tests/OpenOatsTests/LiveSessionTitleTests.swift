import XCTest
@testable import OpenOatsKit

final class LiveSessionTitleTests: XCTestCase {

    func testCalendarTitleWinsOverTopic() {
        let title = LiveSessionController.resolveSessionTitle(
            calendarEventTitle: "Quarterly Review",
            currentTopic: "pricing changes",
            metadataTitle: "zoom.us"
        )
        XCTAssertEqual(title, "Quarterly Review")
    }

    func testFallsBackToTopicWhenNoCalendarTitle() {
        let title = LiveSessionController.resolveSessionTitle(
            calendarEventTitle: nil,
            currentTopic: "pricing changes",
            metadataTitle: "zoom.us"
        )
        XCTAssertEqual(title, "pricing changes")
    }

    func testBlankCalendarTitleFallsThrough() {
        let title = LiveSessionController.resolveSessionTitle(
            calendarEventTitle: "   ",
            currentTopic: "pricing changes",
            metadataTitle: "zoom.us"
        )
        XCTAssertEqual(title, "pricing changes")
    }

    func testFallsBackToMetadataTitleWhenTopicEmpty() {
        let title = LiveSessionController.resolveSessionTitle(
            calendarEventTitle: nil,
            currentTopic: "",
            metadataTitle: "zoom.us"
        )
        XCTAssertEqual(title, "zoom.us")
    }
}
