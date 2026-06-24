import Foundation

/// Looks up the current Google Calendar event by shelling out to the `gog` CLI.
/// All access is gated behind the `gogCalendarEnabled` setting. Fails closed:
/// any error yields no event and never throws into the recording path.
actor GogCalendarClient {

    private let binaryPath: String?

    /// - Parameter binaryPath: explicit path to the `gog` executable; nil auto-detects.
    init(binaryPath: String? = nil) {
        self.binaryPath = binaryPath
    }

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

    // MARK: - Lookup

    /// Return the calendar event overlapping `date` for `account`, or nil.
    /// Mirrors EventKit's ±15-minute window. Never throws; logs a breadcrumb on failure.
    func currentEvent(at date: Date = Date(), account: String) async -> CalendarEvent? {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return nil }

        guard let launch = resolveLaunch() else {
            DiagnosticsSupport.record(category: "calendar", message: "gog binary not found")
            return nil
        }

        let from = date.addingTimeInterval(-15 * 60)
        let to = date.addingTimeInterval(15 * 60)
        let args = launch.leadingArgs + [
            "calendar", "events",
            "--account", trimmedAccount,
            "--from", Self.rfc3339(from),
            "--to", Self.rfc3339(to),
            "-j", "--results-only", "--max", "25", "--no-input",
        ]

        guard let data = await runCapturingStdout(executable: launch.url, arguments: args, timeout: 5) else {
            DiagnosticsSupport.record(category: "calendar", message: "gog lookup failed or timed out")
            return nil
        }

        let candidates = Self.events(fromJSON: data)
        return CalendarEventSelection.bestOverlap(events: candidates, at: date)
    }

    private static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Where to launch gog: an explicit/Homebrew path runs directly; otherwise fall
    /// back to `/usr/bin/env gog` so PATH is consulted.
    private func resolveLaunch() -> (url: URL, leadingArgs: [String])? {
        let fm = FileManager.default
        if let binaryPath, fm.isExecutableFile(atPath: binaryPath) {
            return (URL(fileURLWithPath: binaryPath), [])
        }
        let homebrew = "/opt/homebrew/bin/gog"
        if fm.isExecutableFile(atPath: homebrew) {
            return (URL(fileURLWithPath: homebrew), [])
        }
        let env = "/usr/bin/env"
        if fm.isExecutableFile(atPath: env) {
            return (URL(fileURLWithPath: env), ["gog"])
        }
        return nil
    }

    /// Run a process, draining stdout on a background queue (no pipe-buffer deadlock),
    /// with a hard timeout. Returns stdout on exit 0, else nil.
    private func runCapturingStdout(executable: URL, arguments: [String], timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe() // discard stderr
            let outHandle = outPipe.fileHandleForReading
            let box = SingleResume(continuation)

            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                box.resume(returning: nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            do {
                try process.run()
            } catch {
                watchdog.cancel()
                box.resume(returning: nil)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let data = outHandle.readDataToEndOfFile() // returns at EOF (process closed stdout)
                process.waitUntilExit()
                watchdog.cancel()
                box.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
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

/// Guards a CheckedContinuation so the watchdog and the reader can race to resume
/// exactly once.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<Data?, Never>

    init(_ continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Data?) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
