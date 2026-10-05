import Foundation

/// Software acoustic-echo filter for the mic ("You") channel.
///
/// With voice processing off (see AudioCaptureManager.startMicrophone), the
/// far side's voice reaches the mic through the speakers, so mic chunks mix
/// the user's real speech with an echo of "Them". A whole-chunk overlap test
/// fails on that mix — a 30s mic chunk is rarely >60% echo overall even when
/// half of it is (measured on a real call: 3,771 of the far side's 5,016
/// words leaked into "You"). This filter works sentence-by-sentence instead.
///
/// Far-side phrases are recorded from streaming partials, not just commits: with
/// the system pipeline's longer silence gap, committed "Them" text can lag
/// the mic commit by many seconds, but partials arrive within ~1s of speech.
final class EchoFilter: @unchecked Sendable {
    /// Injectable time source — replay harnesses stamp pool entries with
    /// meeting time instead of wall clock.
    var clock: () -> Date = { Date() }

    private let lock = NSLock()
    private struct TimedWord {
        let at: Date
        let text: String
    }
    private var entries: [[TimedWord]] = []
    private var lastPartialWords: [TimedWord] = []

    /// Longest mic chunk (30s) + commit lag, with slack.
    private let retention: TimeInterval = 45
    /// Allow limited ASR substitutions/insertions/deletions, but require a
    /// contiguous, ordered far-side phrase. Shared topic words alone are not
    /// evidence of echo. Short phrases require an exact match.
    private let maxErrorFraction = 0.25
    /// 1-2 word sentences ("Yeah.", "Okay.") are said by both sides all the
    /// time — not classifiable as echo, always kept.
    private let minSentenceWords = 3

    /// Keep each far-side utterance as one ordered phrase. Matching is
    /// contiguous and ordered, so scattered words never combine into evidence,
    /// while echo whose sentence boundaries ASR placed differently (degraded
    /// echo often loses punctuation) still matches across them.
    func recordFarText(_ text: String) {
        let words = Self.words(text)
        guard !words.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        append(words.map { TimedWord(at: now, text: $0) })
    }

    /// Keep each complete hypothesis instead of concatenating partial deltas.
    /// Deltas can join unrelated ASR revisions into a phrase nobody said.
    func recordFarPartial(_ text: String) {
        let words = Self.words(text)
        lock.lock()
        defer { lock.unlock() }
        guard words != lastPartialWords.map(\.text) else { return }
        // Growing hypotheses must not make old prefix words recent again.
        let now = clock()
        var common = 0
        while common < min(words.count, lastPartialWords.count),
              words[common] == lastPartialWords[common].text { common += 1 }
        let timed = Array(lastPartialWords.prefix(common))
            + words.dropFirst(common).map { TimedWord(at: now, text: $0) }
        lastPartialWords = timed
        if !timed.isEmpty { append(timed) }
    }

    /// Remove echoed sentences from a mic transcription. `since` bounds the
    /// far-side candidates to phrases heard during this chunk (echo is simultaneous
    /// with the far speech, so anything older can't be its source).
    ///
    /// Returns nil when every sentence is echo (drop the utterance), or the
    /// surviving text plus the fraction of words kept — callers scale the
    /// utterance's duration by it so talk-time isn't credited for the far
    /// side's speech.
    func filter(_ text: String, since: Date) -> (text: String, keptFraction: Double)? {
        lock.lock()
        let cutoff = max(since, clock().addingTimeInterval(-retention))
        let candidates = entries.map { phrase in
            phrase.filter { $0.at >= cutoff }.map(\.text)
        }.filter { !$0.isEmpty }
        lock.unlock()
        guard !candidates.isEmpty else { return (text, 1.0) }

        let sentences = Self.sentences(text)
        var kept: [String] = []
        var keptWords = 0
        var totalWords = 0
        for sentence in sentences {
            let ws = Self.words(sentence)
            totalWords += ws.count
            if ws.count >= minSentenceWords,
               candidates.contains(where: { isEcho(ws, of: $0) }) { continue }
            kept.append(sentence)
            keptWords += ws.count
        }
        guard !kept.isEmpty, keptWords > 0 else { return nil }
        if kept.count == sentences.count { return (text, 1.0) }
        return (kept.joined(separator: " "), Double(keptWords) / Double(totalWords))
    }

    /// Edit distance to any contiguous span of ONE far-side utterance.
    /// A free far-side prefix/suffix permits clipped acoustic echo; internal
    /// gaps and reordered/repeated words still consume the error budget.
    /// Memory is linear in the far-side utterance length.
    private func isEcho(_ near: [String], of far: [String]) -> Bool {
        let budget = near.count < 5 ? 0 : Int(Double(near.count) * maxErrorFraction)
        guard far.count >= near.count - budget else { return false }
        var previous = Array(repeating: 0, count: far.count + 1)
        for (i, word) in near.enumerated() {
            var current = Array(repeating: 0, count: far.count + 1)
            current[0] = i + 1
            for j in 1...far.count {
                current[j] = min(previous[j] + 1,
                                 current[j - 1] + 1,
                                 previous[j - 1] + (word == far[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous.min()! <= budget
    }

    private func append(_ words: [TimedWord]) {
        entries.append(words)
        let cutoff = clock().addingTimeInterval(-retention)
        entries.removeAll { ($0.last?.at ?? .distantPast) < cutoff }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "…" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out
    }
}
