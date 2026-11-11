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
/// mic line is therefore HELD (not delivered and retracted later), but only
/// when the system channel was voiced (above the system pipeline's own voice
/// floor) during the line's span; with the far side quiet there is nothing
/// to bleed and the line is delivered at once. Each Them commit, and each new
/// sentence in a Them partial (partials show a word ~1 s after it is said,
/// well before the commit), re-checks the held lines. A held line becomes
/// releasable as soon as the far side's recognized text has moved past its
/// span without its words (`coverMargin`), or after `holdSeconds` at most.
///
/// Release and stop: lines only ever leave the hold through `release` (the
/// capture manager calls it on the main thread and hands lines over
/// synchronously) or `close` (the session calls it on main at Stop, before
/// saving). Background threads may drop a held line or mark it releasable,
/// never deliver it, so a release cannot race the save. After `close` the
/// gate holds nothing and passes every line straight through.
final class ShortEchoGate: @unchecked Sendable {
    /// Largest gap between the mic span and a system sentence span that still
    /// counts as "the same moment". True twins overlap (gap 0); 2 s absorbs
    /// delivery latency, voice-floor differences and the position estimate of
    /// a sentence inside a longer system chunk. Larger would start eating a
    /// genuine "Okay." said a beat after the guest's own.
    static let window: TimeInterval = 2.0
    /// Backstop: longest a short mic line waits for its system twin when the
    /// far text never moves past it (no new far words, throttled partials on
    /// a long far window). Usually `coverMargin` releases it much sooner.
    static let holdSeconds: TimeInterval = 3.0
    /// The far side must have been voiced within this much of the mic span
    /// for bleed to be possible (latency slack only: bleed is simultaneous).
    static let farActivitySlack: TimeInterval = 0.5
    /// A far partial or commit that ARRIVES this long after a held line's
    /// span ended was transcribed from audio that includes the span (the
    /// snapshot is taken at arrival minus inference time). If it still has no
    /// twin, none is coming: release the line.
    static let coverMargin: TimeInterval = 1.0
    /// A sentence first seen in a Them partial at time X was spoken within
    /// this long before X (1 s tick, up to 3x stride on long windows,
    /// inference). Only bounds the search; the stamp itself is the voiced
    /// far audio inside this range.
    static let partialLookback: TimeInterval = 3.0
    static let maxWords = 2
    private let retention: TimeInterval = 30
    /// Far buffers closer than this join one voiced stretch.
    private let voiceJoinGap: TimeInterval = 0.25

    private struct FarSentence {
        let words: [String]
        let t: TimeInterval
        let endT: TimeInterval
    }
    private struct Held {
        let utterance: Utterance
        let deadline: TimeInterval
        var releasable = false
    }

    private let lock = NSLock()
    private var far: [FarSentence] = []
    private var lastPartial: [FarSentence] = []
    private var lastPartialAt: TimeInterval?
    private var voiced: [(t: TimeInterval, endT: TimeInterval)] = []
    private var held: [Held] = []
    private var closed = false
    /// When far text (a partial or commit) last arrived.
    private var lastFarTextAt: TimeInterval?

    enum Decision: Equatable { case drop, hold, deliver }

    /// True for text short enough to be judged by this gate.
    static func isShort(_ text: String) -> Bool {
        let n = EchoFilter.words(text).count
        return n >= 1 && n <= maxWords
    }

    private static func sentenceWords(_ text: String) -> [[String]] {
        EchoFilter.sentences(text).map(EchoFilter.words).filter { !$0.isEmpty }
    }

    /// The system channel carried voice (RMS above the system pipeline's
    /// voice floor) over [from, to], session time.
    func noteFarVoiced(from: TimeInterval, to: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if let last = voiced.last, from <= last.endT + voiceJoinGap {
            voiced[voiced.count - 1].endT = max(last.endT, to)
        } else {
            voiced.append((from, to))
        }
        voiced.removeAll { $0.endT < to - retention }
    }

    /// Record a committed system-channel ("Them") utterance. Returns the held
    /// mic lines it proves to be duplicates (already removed from the hold).
    /// Held lines it moves past are marked releasable (collect via `release`).
    @discardableResult
    func recordFar(_ u: Utterance, now: TimeInterval) -> [Utterance] {
        let sentences = Self.sentenceWords(u.text)
        lock.lock(); defer { lock.unlock() }
        // A commit closes the far window: the next partial starts afresh.
        lastPartial = []; lastPartialAt = nil
        guard !sentences.isEmpty else { return [] }
        far += place(sentences, t: u.t, endT: u.endT)
        prune(newest: max(now, u.endT))
        let dropped = takeMatchedHeld()
        markCovered(now: now)
        return dropped
    }

    /// Record a system-channel partial hypothesis at session time `now`.
    /// Only sentences that are really new get a new time; ones kept from the
    /// previous partial keep theirs, and a revised sentence keeps the place
    /// of the text it replaced. Empty text = window committed.
    @discardableResult
    func recordFarPartial(_ text: String, now: TimeInterval) -> [Utterance] {
        let sentences = Self.sentenceWords(text)
        lock.lock(); defer { lock.unlock() }
        guard !sentences.isEmpty else {
            lastPartial = []; lastPartialAt = nil
            return []
        }
        // Align with the previous partial in order: matched sentences are
        // anchors that keep their stamps.
        var matchedOld: [Int?] = Array(repeating: nil, count: sentences.count)
        var j = 0
        for (i, words) in sentences.enumerated() {
            if let k = lastPartial[j...].firstIndex(where: { $0.words == words }) {
                matchedOld[i] = k; j = k + 1
            }
        }
        let lastAnchor = matchedOld.lastIndex { $0 != nil }
        var stamped: [FarSentence] = []
        var i = 0
        while i < sentences.count {
            if let k = matchedOld[i] { stamped.append(lastPartial[k]); i += 1; continue }
            // A run of unmatched sentences.
            var runEnd = i
            while runEnd + 1 < sentences.count, matchedOld[runEnd + 1] == nil { runEnd += 1 }
            let run = Array(sentences[i...runEnd])
            let placed: [FarSentence]
            if let lastAnchor, i < lastAnchor {
                // Revised text before an unchanged sentence: spoken where the
                // text it replaced was, between the neighbouring anchors.
                let prev = stamped.last
                let next = lastPartial[matchedOld[runEnd + 1]!]
                let from = prev?.endT ?? (lastPartial.first?.t ?? next.t)
                placed = place(run, t: min(from, next.t), endT: next.t)
            } else {
                // Genuinely new trailing text: spoken in the voiced far audio
                // since the previous partial's snapshot, within the lookback.
                var lower = now - Self.partialLookback
                if let prevAt = lastPartialAt { lower = max(lower, prevAt - Self.coverMargin) }
                let span = voicedSpan(from: lower, to: now) ?? (lower, now)
                placed = place(run, t: span.0, endT: span.1)
            }
            stamped += placed
            far += placed
            i = runEnd + 1
        }
        lastPartial = stamped
        lastPartialAt = now
        prune(newest: now)
        let dropped = takeMatchedHeld()
        markCovered(now: now)
        return dropped
    }

    /// Judge a mic utterance at session time `now`. `onSpeakers` is true only
    /// while the output route is the built-in speakers AND system audio is
    /// being captured; otherwise every line is delivered untouched.
    /// `.hold` means it was stored: it leaves through `recordFar` /
    /// `recordFarPartial` (dropped) or `release` / `close` (delivered).
    func submit(_ u: Utterance, onSpeakers: Bool, now: TimeInterval) -> Decision {
        guard onSpeakers, Self.isShort(u.text) else { return .deliver }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return .deliver }
        if matches(u) { return .drop }
        // Far side not voiced during this line: nothing could bleed.
        guard farVoiced(from: u.t - Self.farActivitySlack,
                        to: u.endT + Self.farActivitySlack) else { return .deliver }
        // Far text already moved past this line without its words.
        if let at = lastFarTextAt, at >= u.endT + Self.coverMargin { return .deliver }
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

    /// Mark every held line releasable (route left the speakers, system audio
    /// lost). They come out on the next `release`.
    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        for i in held.indices { held[i].releasable = true }
    }

    var hasReleasable: Bool {
        lock.lock(); defer { lock.unlock() }
        return held.contains { $0.releasable }
    }

    /// Held lines that are done waiting (no twin is coming, or the backstop
    /// expired), in time order. Kept: they are real speech. Main thread only.
    func release(now: TimeInterval) -> [Utterance] {
        lock.lock(); defer { lock.unlock() }
        let due = held.filter { $0.releasable || $0.deadline <= now }.map(\.utterance)
        held.removeAll { $0.releasable || $0.deadline <= now }
        return due.sorted { $0.t < $1.t }
    }

    /// Stop: hand back everything still held and pass every later line
    /// straight through. Atomic with `submit`, so a line in flight is either
    /// returned here or delivered untouched, never held after this.
    func close() -> [Utterance] {
        lock.lock(); defer { lock.unlock() }
        closed = true
        let all = held.map(\.utterance)
        held.removeAll()
        return all.sorted { $0.t < $1.t }
    }

    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    // Caller holds the lock for everything below.

    /// Spread sentences over [t, endT] by word offset, counting only the
    /// far side's voiced time (pauses carry no words). One sentence owns the
    /// whole span; several are widened by a fifth of the voiced time either
    /// side for uneven pace, so a word said early in a long chunk does not
    /// claim a reply at its end, and "Bye." before a pause does not claim a
    /// "Bye." the user says after it. Without voice data: linear.
    private func place(_ sentences: [[String]], t: TimeInterval,
                       endT: TimeInterval) -> [FarSentence] {
        let total = sentences.reduce(0) { $0 + $1.count }
        var stretches = voiced.filter { $0.endT >= t && $0.t <= endT }
            .map { (t: max($0.t, t), endT: min($0.endT, endT)) }
        if stretches.reduce(0, { $0 + $1.endT - $1.t }) <= 0 { stretches = [(t, max(t, endT))] }
        let voicedTotal = stretches.reduce(0) { $0 + $1.endT - $1.t }
        // Session time `x` seconds into the voiced timeline. On a stretch
        // boundary a start belongs to the next stretch, an end to this one.
        func timeAt(_ x: TimeInterval, start: Bool) -> TimeInterval {
            var left = x
            for s in stretches {
                let d = s.endT - s.t
                if start ? left < d : left <= d { return s.t + left }
                left -= d
            }
            return stretches.last!.endT
        }
        let slack = sentences.count == 1 ? 0 : voicedTotal * 0.2
        var offset = 0
        return sentences.map { words in
            let start = timeAt(voicedTotal * Double(offset) / Double(total), start: true)
            offset += words.count
            let end = timeAt(voicedTotal * Double(offset) / Double(total), start: false)
            return FarSentence(words: words, t: start - slack, endT: end + slack)
        }
    }

    /// First voiced onset to last voiced end inside [from, to], clipped.
    private func voicedSpan(from: TimeInterval, to: TimeInterval) -> (TimeInterval, TimeInterval)? {
        let inside = voiced.filter { $0.endT >= from && $0.t <= to }
        guard let first = inside.first, let last = inside.last else { return nil }
        return (max(first.t, from), min(last.endT, to))
    }

    private func farVoiced(from: TimeInterval, to: TimeInterval) -> Bool {
        voiced.contains { $0.endT >= from && $0.t <= to }
    }

    /// Far text arrived at `now`: held lines whose span ended `coverMargin`
    /// before it were in the audio it was transcribed from.
    private func markCovered(now: TimeInterval) {
        lastFarTextAt = max(lastFarTextAt ?? now, now)
        for i in held.indices where now >= held[i].utterance.endT + Self.coverMargin {
            held[i].releasable = true
        }
    }

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
