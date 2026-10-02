import Foundation
import NaturalLanguage

/// Names the language of transcript text with Apple's on-device
/// NLLanguageRecognizer, constrained to the 25 languages MeetMouse can
/// transcribe. Text only — no audio, no network.
///
/// Measured on meeting-style lines (2026-10-01): every sentence of 2+ words
/// across the 25 languages was right at ~1.0 confidence except Slovenian,
/// which reads as Croatian. The misses were single words ("OK.") that land
/// near 0.2–0.3, so the confidence floor drops them instead of guessing.
enum TranscriptLanguageDetector {
    static let minimumConfidence = 0.6

    private static let constraints = MeetingLanguageSelection.specificLanguages
        .map { NLLanguage(rawValue: $0.rawValue) }

    /// The language of one line or turn, or nil when it's too short or
    /// ambiguous to call.
    static func language(of text: String) -> MeetingLanguageSelection? {
        guard text.contains(where: \.isLetter) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= minimumConfidence else { return nil }
        return MeetingLanguageSelection(rawValue: language.rawValue).flatMap { $0.isSpecific ? $0 : nil }
    }

    /// `language(of:)` memoized for views that re-render whole transcripts
    /// on every live update (per-line tags). Main-thread only.
    @MainActor static func cachedLanguage(of text: String) -> MeetingLanguageSelection? {
        if let hit = cache[text] { return hit }
        if cache.count > 2_000 { cache.removeAll() }
        let detected = language(of: text)
        cache[text] = .some(detected)
        return detected
    }
    @MainActor private static var cache: [String: MeetingLanguageSelection?] = [:]

    /// Words heard per language, accumulated line by line during a meeting.
    struct Tally: Equatable, Sendable {
        private(set) var words: [MeetingLanguageSelection: Int] = [:]

        mutating func add(_ text: String) {
            guard let language = TranscriptLanguageDetector.language(of: text) else { return }
            words[language, default: 0] += text.split(whereSeparator: \.isWhitespace).count
        }

        /// Languages carrying a real share of the meeting, most-spoken first.
        /// A stray detected line (a name, a borrowed phrase) stays below 15%.
        var spoken: [MeetingLanguageSelection] {
            let total = words.values.reduce(0, +)
            guard total > 0 else { return [] }
            return words.filter { Double($0.value) / Double(total) >= 0.15 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
                .map(\.key)
        }

        var dominant: MeetingLanguageSelection? { spoken.first }

        /// More than one language is really in play — the cue to tag lines.
        var isMultilingual: Bool { spoken.count > 1 }
    }

    static func tally(_ texts: [String]) -> Tally {
        var tally = Tally()
        for text in texts { tally.add(text) }
        return tally
    }
}
