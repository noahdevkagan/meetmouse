import Foundation

/// Shared transcript fixes (decisions.md 2026-11-02 "transcript fixes").
///
/// `Resources/common_corrections.json` holds heard→corrected pairs that at
/// least three different Macs taught with "Fix a misheard term" while opted in
/// to "Help improve transcripts". Only the weekly improve PR writes it, and a
/// human merges that PR. Here the pairs become extra VocabularyNormalizer
/// terms, for English meetings only, and never where the user's own
/// vocabulary already says something about the same words: the user wins.
///
/// Pure apart from `bundled`, so tests/transcripts compiles it standalone.
enum CommonCorrections {
    struct Entry: Codable, Equatable {
        var heard: String
        var corrected: String
        var installs: Int?
    }

    struct File: Codable {
        var entries: [Entry]
    }

    static let resourceName = "common_corrections"

    static func load(from data: Data) -> [Entry] {
        (try? JSONDecoder().decode(File.self, from: data))?.entries ?? []
    }

    /// The bundled list, read once.
    static let bundled: [Entry] = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return load(from: data)
    }()

    /// Extra normalizer terms for a session. Empty for non-English meetings
    /// (pairs were learned from English speech). Skips any entry whose heard
    /// or corrected words the user's vocabulary (or the built-in defaults)
    /// already covers, so a personal rule is never overridden or recased.
    static func terms(_ entries: [Entry] = bundled, userVocabulary: String,
                      isEnglish: Bool) -> [VocabularyNormalizer.Term] {
        guard isEnglish, !entries.isEmpty else { return [] }
        var taken = Set<String>()
        for term in VocabularyNormalizer.defaultTerms + VocabularyNormalizer.parse(userVocabulary) {
            taken.insert(collapse(term.canonical).lowercased())
            for garble in term.garbles { taken.insert(collapse(garble).lowercased()) }
        }
        var seen = Set<String>()
        return entries.compactMap { entry in
            let heard = collapse(entry.heard)
            let corrected = collapse(entry.corrected)
                .replacingOccurrences(of: "=", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let heardKey = heard.lowercased(), correctedKey = corrected.lowercased()
            guard !heard.isEmpty, !corrected.isEmpty, heardKey != correctedKey,
                  !taken.contains(heardKey), !taken.contains(correctedKey),
                  seen.insert(heardKey).inserted else { return nil }
            return VocabularyNormalizer.Term(corrected, garbles: [heard])
        }
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
