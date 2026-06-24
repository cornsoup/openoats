import XCTest
@testable import OpenOatsKit

final class CalendarFilterTests: XCTestCase {

    func testEmptySelectionKeepsAny() {
        XCTAssertTrue(CalendarFilter.keep("any-id", selected: []))
        XCTAssertTrue(CalendarFilter.keep("", selected: []))
    }

    func testNonEmptyKeepsOnlyMembers() {
        let selected: Set<String> = ["a", "b"]
        XCTAssertTrue(CalendarFilter.keep("a", selected: selected))
        XCTAssertTrue(CalendarFilter.keep("b", selected: selected))
    }

    func testNonMemberExcluded() {
        XCTAssertFalse(CalendarFilter.keep("c", selected: ["a", "b"]))
    }
}
