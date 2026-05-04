import AppKit
import Foundation

enum TranscriptClipboard {
    /// Copies a transcript to the system pasteboard, formatted with
    /// `[HH:mm:ss] Speaker: text` per line.
    static func copy(_ utterances: [Utterance]) {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm:ss"
        let lines = utterances.map { u in
            "[\(timeFmt.string(from: u.timestamp))] \(u.speaker.displayLabel): \(u.displayText)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
