import Foundation

/// Drops 1-2 word speaker-bleed duplicates on the mic ("You") channel.
///
/// EchoFilter deliberately never classifies sentences shorter than three
/// words as echo, because both sides really say "Okay." and "Yeah.". On open
/// built-in speakers that leaves a hole: the guest's one-word line reaches the
/// mic and shows up twice, as You (bleed) and as Them (system audio).
///
/// The evidence used here is the system channel itself: a short mic line is
/// echo only when a "Them" sentence with exactly the same normalized words
/// overlaps it in time (or sits within `window` seconds of it). The mic copy
/// is dropped and the Them copy stays. Callers enable it only on the built-in
/// speaker route; any other route never constructs a submission.
///
/// Arrival order matters: the mic pipeline commits after 0.9 s of silence and
/// the system pipeline after 2.0 s (plus inference), so the mic copy usually
/// lands first. Short mic lines are therefore held up to `holdSeconds`, and
/// each Them commit re-checks the held lines. A line with no matching system
/// sentence is always delivered when the hold expires, with its original
/// timestamps (the view model inserts by time).
final class ShortEchoGate: @unchecked Sendable {
    /// Largest gap between the mic and system utterance spans that still
    /// counts as "the same moment". Both channels stamp spans from the same
    /// session clock (first voiced audio to last voiced audio), so true
    /// duplicates overlap; 2 s absorbs ScreenCaptureKit vs mic latency,
    /// different voice floors (0.002 vs 0.006) and a far utterance that
    /// merged neighbouring speech. Larger risks eating a genuine reply that
    /// follows the guest's "Okay." by a beat.
    static let window: TimeInterval = 2.0
    /// Longest a short mic line waits for its system twin. Covers the system
    /// commit gap (2.0 s) minus the mic's (0.9 s), plus inference and slow
    /// partial refresh, with margin. Only 1-2 word lines on speakers wait.
    static let holdSeconds: TimeInterval = 4.0
    static let maxWords = 2
    private let retention: TimeInterval = 20

    private struct FarSentence {
        let words: [String]
        let t: TimeInterval
        let endT: TimeInterval
    }
    private struct Held {
        let utterance: Utterance
        let deadline: Date
    }

    private let lock = NSLock()
    private var far: [FarSentence] = []
    private var held: [Held] = []

    enum Decision { case drop, hold, deliver }

    /// True for text short enough to be judged by this gate.
    static func isShort(_ text: String) -> Bool {
        let n = EchoFilter.words(text).count
        return n >= 1 && n <= maxWords
    }

    /// Record a committed system-channel ("Them") utterance. Returns the held
    /// mic lines it proves to be duplicates (already removed from the hold).
    @discardableResult
    func recordFar(_ u: Utterance) -> [Utterance] {
        lock.lock(); defer { lock.unlock() }
        for sentence in EchoFilter.sentences(u.text) {
            let words = EchoFilter.words(sentence)
            if !words.isEmpty { far.append(FarSentence(words: words, t: u.t, endT: u.endT)) }
        }
        let newest = far.map(\.endT).max() ?? 0
        far.removeAll { $0.endT < newest - retention }
        var dropped: [Utterance] = []
        held.removeAll { h in
            if matches(h.utterance) { dropped.append(h.utterance); return true }
            return false
        }
        return dropped
    }

    /// Judge a mic utterance. `.hold` means it was stored; collect it later
    /// from `recordFar` (dropped) or `expire` (delivered).
    func submit(_ u: Utterance, now: Date) -> Decision {
        guard Self.isShort(u.text) else { return .deliver }
        lock.lock(); defer { lock.unlock() }
        if matches(u) { return .drop }
        held.append(Held(utterance: u, deadline: now.addingTimeInterval(Self.holdSeconds)))
        return .hold
    }

    /// Held lines whose wait is over: no system twin arrived, so keep them.
    func expire(now: Date) -> [Utterance] {
        lock.lock(); defer { lock.unlock() }
        let due = held.filter { $0.deadline <= now }.map(\.utterance)
        held.removeAll { $0.deadline <= now }
        return due
    }

    /// Everything still held (route change, stop): deliver, never lose.
    func flushAll() -> [Utterance] {
        lock.lock(); defer { lock.unlock() }
        let all = held.map(\.utterance)
        held.removeAll()
        return all
    }

    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    /// Caller holds the lock. Every sentence of the mic line must equal a
    /// system sentence whose span overlaps it within `window`.
    private func matches(_ u: Utterance) -> Bool {
        let sentences = EchoFilter.sentences(u.text).map(EchoFilter.words).filter { !$0.isEmpty }
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
