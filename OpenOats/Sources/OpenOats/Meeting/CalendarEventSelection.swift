import Foundation

/// Pure event-selection logic for calendar sources (EventKit).
/// Callers exclude all-day / cancelled events before calling.
enum CalendarEventSelection {
    /// Choose the event whose start is closest to `date`, breaking ties by the
    /// earlier start. Returns nil for an empty input.
    static func bestOverlap(events: [CalendarEvent], at date: Date) -> CalendarEvent? {
        events.min { a, b in
            let distA = abs(a.startDate.timeIntervalSince(date))
            let distB = abs(b.startDate.timeIntervalSince(date))
            if distA != distB { return distA < distB }
            return a.startDate < b.startDate
        }
    }
}
