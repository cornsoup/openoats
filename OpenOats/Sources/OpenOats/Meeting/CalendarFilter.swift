import Foundation

/// Pure calendar-selection predicate shared by `CalendarManager`.
enum CalendarFilter {
    /// A calendar is kept when no selection is set (empty = all calendars),
    /// or when its identifier is in the selected set.
    static func keep(_ calendarID: String, selected: Set<String>) -> Bool {
        selected.isEmpty || selected.contains(calendarID)
    }
}

/// Default calendars to pre-select on first authorized run.
enum MeetingCalendarDefaults {
    static let titles: Set<String> = ["Test IIT"]
}
