import Foundation

/// Surfaces the running binary's version and build date in the UI so it's
/// obvious at a glance which build is in front of you. Particularly useful
/// when an installed `/Applications/OpenOats.app` and a fresh debug binary
/// can both be launched accidentally.
enum BuildInfo {
    /// `CFBundleShortVersionString` from Info.plist. `nil` for the bare SPM
    /// debug binary, which has no Info.plist.
    static var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }

    /// Modification time of the running executable. For SPM builds this is
    /// when the linker last produced the binary; for shipped builds it's the
    /// release time baked into the .app.
    static var buildDate: Date {
        guard
            let path = Bundle.main.executablePath,
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let date = attrs[.modificationDate] as? Date
        else {
            return Date.distantPast
        }
        return date
    }

    /// Compact label for the status bar: e.g. `1.22.0 · May 4` or `dev · May 4`.
    static var shortLabel: String {
        "\(versionString) · \(shortDateString(buildDate))"
    }

    /// Tooltip-friendly form: e.g. `2026-05-04 14:32`.
    static var fullBuildDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: buildDate)
    }

    private static func shortDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
