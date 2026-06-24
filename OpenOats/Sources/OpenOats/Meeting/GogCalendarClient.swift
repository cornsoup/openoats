import Foundation

/// Looks up the current Google Calendar event by shelling out to the `gog` CLI.
/// All access is gated behind the `gogCalendarEnabled` setting. Fails closed:
/// any error yields no event and never throws into the recording path.
actor GogCalendarClient {

    // MARK: - JSON decoding (pure, testable)

    /// Parse `gog calendar events -j --results-only` output — a bare JSON array,
    /// or the `{ "events": [...] }` envelope — into CalendarEvents.
    /// All-day events (start.date with no dateTime) and cancelled events are excluded.
    static func events(fromJSON data: Data) -> [CalendarEvent] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        let raw: [GogEvent]
        if let array = try? decoder.decode([GogEvent].self, from: data) {
            raw = array
        } else if let envelope = try? decoder.decode(GogEventsPayload.self, from: data) {
            raw = envelope.events
        } else {
            return []
        }
        return raw.compactMap { $0.toCalendarEvent() }
    }
}

// MARK: - gog JSON shapes

private struct GogEventsPayload: Decodable {
    let events: [GogEvent]
}

private struct GogEvent: Decodable {
    let id: String?
    let summary: String?
    let status: String?
    let start: GogDate?
    let end: GogDate?
    let organizer: GogPerson?
    let attendees: [GogAttendee]?
    let hangoutLink: String?
    let location: String?

    func toCalendarEvent() -> CalendarEvent? {
        guard status != "cancelled" else { return nil }
        // Require a timed start/end; events with only `date` are all-day and excluded.
        guard let startStr = start?.dateTime, let endStr = end?.dateTime,
              let startDate = parseGogDateTime(startStr),
              let endDate = parseGogDateTime(endStr) else {
            return nil
        }

        let hangoutURL = hangoutLink.flatMap { URL(string: $0) }
        let meetingURL = CalendarMeetingLinkResolver.meetingURL(
            rawURL: hangoutURL, notes: nil, location: location
        )
        let isOnline = CalendarMeetingLinkResolver.isOnlineMeeting(
            rawURL: hangoutURL, notes: nil, location: location
        )

        return CalendarEvent(
            id: id ?? UUID().uuidString,
            title: summary ?? "Untitled Event",
            startDate: startDate,
            endDate: endDate,
            externalIdentifier: nil,
            calendarID: nil,
            calendarTitle: nil,
            calendarColorHex: nil,
            organizer: organizer?.displayName ?? organizer?.email,
            participants: (attendees ?? []).map { Participant(name: $0.displayName, email: $0.email) },
            isOnlineMeeting: isOnline,
            meetingURL: meetingURL
        )
    }
}

private struct GogDate: Decodable {
    let dateTime: String?
    let date: String?
}

private struct GogPerson: Decodable {
    let email: String?
    let displayName: String?
}

private struct GogAttendee: Decodable {
    let email: String?
    let displayName: String?
}

/// Parse an RFC3339 timestamp from gog, tolerating fractional seconds.
private func parseGogDateTime(_ string: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
}
