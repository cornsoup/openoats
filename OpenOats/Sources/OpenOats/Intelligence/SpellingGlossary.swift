import Foundation

/// Parses and unions the user's spelling glossary so transcript-cleanup
/// passes can include it in their LLM system prompts. Pure, stateless.
enum SpellingGlossary {

    /// Returns the deduplicated list of glossary terms for a session.
    ///
    /// - `global` is the user's app-wide list, one term per line. Empty lines
    ///   and lines starting with `#` are dropped. Whitespace per line is
    ///   trimmed.
    /// - `folderGlossary` is the optional per-folder additions in the same
    ///   format. Pass `nil` (or `""`) when there is no folder.
    ///
    /// Order is global-first, then folder additions. Dedup is case-
    /// insensitive on the trimmed term; the first occurrence wins.
    static func terms(global: String, folderGlossary: String?) -> [String] {
        // Locale-stable lowercasing for dedup keys — avoids surprises with
        // locale-sensitive case mapping (notably tr_TR's dotted/dotless I).
        let dedupLocale = Locale(identifier: "en_US_POSIX")
        var seen = Set<String>()
        var result: [String] = []
        for line in parse(global) {
            let key = line.lowercased(with: dedupLocale)
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(line)
        }
        if let folderGlossary {
            for line in parse(folderGlossary) {
                let key = line.lowercased(with: dedupLocale)
                if seen.contains(key) { continue }
                seen.insert(key)
                result.append(line)
            }
        }
        return result
    }

    /// Returns the prompt block that the cleaners append to their system
    /// prompt. Empty string when there are no terms, so callers can
    /// unconditionally append.
    static func promptBlock(terms: [String]) -> String {
        guard !terms.isEmpty else { return "" }
        let bullets = terms.map { "- \($0)" }.joined(separator: "\n")
        return """

        SPELLING GLOSSARY (proper names and terms used by the speaker; transcription errors are common with these):

        \(bullets)

        If a word in the transcript phonetically matches one of these but is spelled differently, replace it with the version from this list. Do NOT modify words that don't phonetically match a glossary entry. Do NOT add these names to text where they don't belong.
        """
    }

    private static func parse(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard !trimmed.hasPrefix("#") else { return nil }
            return trimmed
        }
    }
}
