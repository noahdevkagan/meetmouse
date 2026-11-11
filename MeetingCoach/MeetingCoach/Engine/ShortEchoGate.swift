import Foundation

/// Drops 1-2 word speaker-bleed duplicates on the mic ("You") channel.
///
/// EchoFilter deliberately never classifies sentences shorter than three
/// words as echo, because both sides really say "Okay." and "Yeah.". On open
/// built-in speakers that leaves a hole: the guest's one-word line reaches the
/// mic and shows up twice, as You (bleed) and as Them (system audio).
///
/// The evidence used here is the system channel itself, never the text alone:
/// a short mic line is echo only when the system channel transcribed exactly
/// the same normalized words at the same moment. The mic copy is dropped and
/// the Them copy stays. AudioCaptureManager consults the gate only while the
/// output route is the built-in speakers and system audio is captured; on any
/// other route, or mic-only, every mic line bypasses it.
///
/// Clock: every time here is session-relative seconds, the clock both
/// pipelines stamp utterances with (wall time of the first/last voiced buffer
/// minus the shared session start). Bleed is acoustically simultaneous with
/// the far audio, so true twins overlap; the residual offset is buffer
/// delivery latency (mic tap ~85 ms, ScreenCaptureKit tens of ms) and the
/// different voice floors (mic 0.006 hears only the loud core of the bleed,
/// system 0.002 hears the whole word), which makes the mic span a sub-span.
///
/// Arrival order: the mic commits after 0.9 s of silence, the system channel
/// after 2.0 s (plus inference), so the mic copy usually lands first. A short
/// mic line is therefore HELD (not delivered and retracted later) for up to
/// `holdSeconds`, but only when the system channel carried audio during the
/// line; with the far side quiet there is nothing to bleed and the line is
/// delivered at once. Each Them commit, and each new sentence in a Them
/// partial (partials show a word ~1 s after it is said, well before the
/// commit), re-checks the held lines. A held line with no twin is delivered
/// with its original timestamps when the hold expires.
final class ShortEchoGate: @unchecked Sendable {
    /// Largest gap between the mic span and a committed system sentence span
    /// that still counts as "the same moment". True twins overlap (gap 0);
    /// 2 s absorbs delivery latency, voice-floor differences and the position
    /// estimate of a sentence inside a longer system chunk. Larger would start
    /// eating a genuine "Okay." said a beat after the guest's own.
    static let window: TimeInterval = 2.0
    /// Longest a short mic line waits for its system twin. The twin shows up
    /// as a Them partial within one 1 s tick (+ inference) of the far word,
    /// i.e. about when the mic commits; the Them commit follows ~1.1 s later
    /// (2.0 vs 0.9 s silence). 3 s covers both plus a throttled partial on a
    /// long far window. Only lines spoken while the far side was audible wait.
    static let holdSeconds: TimeInterval = 3.0
    /// The far side must have been audible at or after this long before the
    /// mic line started for bleed to be possible (latency slack only: bleed
    /// is simultaneous).
    static let farActivitySlack: TimeInterval = 0.5
    /// A sentence first seen in a Them partial at time X was spoken within
    /// this long before X (1 s tick, up to 3x stride on long windows,
    /// inference).
    static let partialLookback: TimeInterval = 3.0
    static let maxWords = 2
    private let retention: TimeInterval = 30

    private struct FarSentence {
        let words: [String]
        let t: TimeInterval
        let endT: TimeInterval
    }
    private struct Held {
        let utterance: Utterance
        let deadline: TimeInterval
    }

    private let lock = NSLock()
    private var far: [FarSentence] = []
    private var lastPartialSentences: [[String]] = []
    private var held: [Held] = []

    enum Decision: Equatable { case drop, hold, deliver }

    /// True for text short enough to be judged by this gate.
    static func isShort(_ text: String) -> Bool {
        let n = EchoFilter.words(text).count
        return n >= 1 && n <= maxWords
    }

    private static func sentenceWords(_ text: String) -> [[String]] {
        EchoFilter.sentences(text).map(EchoFilter.words).filter { !$0.isEmpty }
    }

    /// Record a committed system-channel ("Them") utterance. Returns the held
    /// mic lines it proves to be duplicates (already removed from the hold).
    @discardableResult
    func recordFar(_ u: Utterance) -> [Utterance] {
        let sentences = Self.sentenceWords(u.text)
        let total = sentences.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        // One sentence owns the whole span. Several share it: place each by
        // its word offset, widened by a fifth of the span either side for
        // pauses and uneven pace, so a word said early in a long chunk does
        // not claim a reply at its end.
        let slack = sentences.count == 1 ? 0 : u.duration * 0.2
        var offset = 0
        for words in sentences {
            let start = u.t + u.duration * Double(offset) / Double(total)
            offset += words.count
            let end = u.t + u.duration * Double(offset) / Double(total)
            far.append(FarSentence(words: words, t: start - slack, endT: end + slack))
        }
        prune(newest: u.endT)
        return takeMatchedHeld()
    }

    /// Record a system-channel partial hypothesis at session time `now`.
    /// Sentences new since the previous partial are stamped as just spoken;
    /// unchanged ones keep their first stamp. Empty text = window committed.
    @discardableResult
    func recordFarPartial(_ text: String, now: TimeInterval) -> [Utterance] {
        let sentences = Self.sentenceWords(text)
        lock.lock(); defer { lock.unlock() }
        var common = 0
        while common < min(sentences.count, lastPartialSentences.count),
              sentences[common] == lastPartialSentences[common] { common += 1 }
        lastPartialSentences = sentences
        let fresh = sentences.dropFirst(common)
        guard !fresh.isEmpty else { return [] }
        for words in fresh {
            far.append(FarSentence(words: words, t: now - Self.partialLookback, endT: now))
        }
        prune(newest: now)
        return takeMatchedHeld()
    }

    /// Judge a mic utterance at session time `now`. `onSpeakers` is true only
    /// while the output route is the built-in speakers AND system audio is
    /// being captured; otherwise every line is delivered untouched.
    /// `farLoudAt` is the session time the system channel last carried audio.
    /// `.hold` means it was stored: collect it later from `recordFar` /
    /// `recordFarPartial` (dropped) or `expire` / `drainAll` (delivered).
    func submit(_ u: Utterance, onSpeakers: Bool,
                farLoudAt: TimeInterval, now: TimeInterval) -> Decision {
        guard onSpeakers, Self.isShort(u.text) else { return .deliver }
        lock.lock(); defer { lock.unlock() }
        if matches(u) { return .drop }
        // Far side silent since before this line began: nothing could bleed.
        guard farLoudAt >= u.t - Self.farActivitySlack else { return .deliver }
        held.append(Held(utterance: u, deadline: now + Self.holdSeconds))
        return .hold
    }

    /// Hide a live mic partial that is already a known short twin, so the
    /// bleed copy does not flash as the user's pending line.
    func hidesPartial(_ text: String, onSpeakers: Bool, now: TimeInterval) -> Bool {
        guard onSpeakers, Self.isShort(text) else { return false }
        lock.lock(); defer { lock.unlock() }
        return matches(Utterance(t: now - 1.5, speaker: "You", text: text, endT: now))
    }

    /// Held lines whose wait is over: no system twin arrived, so keep them.
    func expire(now: TimeInterval) -> [Utterance] {
        lock.lock(); defer { lock.unlock() }
        let due = held.filter { $0.deadline <= now }.map(\.utterance)
        held.removeAll { $0.deadline <= now }
        return due
    }

    /// Everything still held (route change, stop): deliver, never lose.
    func drainAll() -> [Utterance] {
        lock.lock(); defer { lock.unlock() }
        let all = held.map(\.utterance)
        held.removeAll()
        return all
    }

    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    // Caller holds the lock for everything below.

    private func prune(newest: TimeInterval) {
        far.removeAll { $0.endT < newest - retention }
    }

    private func takeMatchedHeld() -> [Utterance] {
        var dropped: [Utterance] = []
        held.removeAll { h in
            if matches(h.utterance) { dropped.append(h.utterance); return true }
            return false
        }
        return dropped
    }

    /// Every sentence of the mic line must equal a system sentence whose
    /// span is within `window` of the mic span.
    private func matches(_ u: Utterance) -> Bool {
        let sentences = Self.sentenceWords(u.text)
        guard !sentences.isEmpty else { return false }
        return sentences.allSatisfy { near in
            far.contains { f in
                guard f.words == near else { return false }
                let gap = max(0, max(u.t, f.t) - min(u.endT, f.endT))
                return gap <= Self.window
            }
        }
    }
}
