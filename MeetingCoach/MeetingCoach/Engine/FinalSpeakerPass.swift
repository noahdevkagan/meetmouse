import Foundation

/// One finalized "who spoke when" span, session-relative seconds.
struct SpeakerSegment: Sendable, Equatable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
}

/// The whole-call speaker pass that runs when a meeting stops.
///
/// Live labels come from a streaming model that decides who is talking
/// within a fraction of a second and can never revise it. That is the right
/// trade during the call and the wrong one for the saved record: on a call
/// with several remote people it swaps their lines. Once the call is over
/// the whole recording is available, so a clustering diarizer (FluidAudio's
/// offline pipeline) goes over it once and the transcript is relabeled from
/// that before it is saved and before notes are written.
///
/// This file is the part with no model in it: mapping the offline pass's
/// anonymous clusters onto the names the live call already carries, and the
/// temp file the call's audio is kept in meanwhile. `SpeakerDiarizer` owns
/// the model.
enum FinalSpeakerPass {
    /// Shorter recordings keep their live labels: too little speech to
    /// cluster, and nothing a second pass would fix.
    static let minSeconds: TimeInterval = 45

    /// How long notes wait for the pass before going ahead with live labels.
    /// The pass still finishes and relabels the saved transcript after that.
    static let notesWaitSeconds: TimeInterval = 120

    /// A span from the offline pass: `cluster` is an arbitrary id that only
    /// means "the same voice as other spans with this id".
    struct ClusterSpan: Sendable, Equatable {
        let cluster: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// The offline spans under display labels.
    ///
    /// Each cluster takes the live label it shares the most speech with, one
    /// cluster per label, largest overlaps first: with two named people whose
    /// lines the live model mixed up, each cluster still spent most of its
    /// time under one of the names, and that is the name it keeps. A cluster
    /// left without a label (the live model never told that voice apart) gets
    /// the lowest free "`prefix` N". A live label no cluster claims was a
    /// voice the live model invented, and disappears.
    ///
    /// Returns nil when the offline result should not replace the live one:
    /// it found no speech, or far less than the live model did.
    static func relabel(offline: [ClusterSpan], live: [SpeakerSegment],
                        labelPrefix: String) -> [SpeakerSegment]? {
        let spans = offline.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !spans.isEmpty else { return nil }
        let offlineSpeech = spans.reduce(0.0) { $0 + ($1.end - $1.start) }
        let liveSpeech = live.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        guard liveSpeech <= 0 || offlineSpeech >= liveSpeech * 0.4 else { return nil }

        // Seconds each cluster shares with each live label.
        var shared: [String: [String: TimeInterval]] = [:]
        var speech: [String: TimeInterval] = [:]
        let liveSorted = live.sorted { $0.start < $1.start }
        for span in spans {
            speech[span.cluster, default: 0] += span.end - span.start
            for seg in liveSorted {
                if seg.start >= span.end { break }
                let overlap = min(seg.end, span.end) - max(seg.start, span.start)
                if overlap > 0 { shared[span.cluster, default: [:]][seg.speaker, default: 0] += overlap }
            }
        }

        var pairs: [(cluster: String, label: String, seconds: TimeInterval)] = []
        for (cluster, labels) in shared {
            for (label, seconds) in labels { pairs.append((cluster, label, seconds)) }
        }
        // Stable order: equal overlaps must not flip between runs.
        pairs.sort { ($0.seconds, $1.cluster, $1.label) > ($1.seconds, $0.cluster, $0.label) }

        var labelOf: [String: String] = [:]
        var taken = Set<String>()
        for pair in pairs where labelOf[pair.cluster] == nil && !taken.contains(pair.label) {
            // A sliver of overlap is the live model's boundary error, not
            // evidence the two are the same voice.
            guard pair.seconds >= min(2, (speech[pair.cluster] ?? 0) * 0.2) else { continue }
            labelOf[pair.cluster] = pair.label
            taken.insert(pair.label)
        }

        // Unlabeled clusters, most speech first, take the lowest free slot.
        let liveLabels = Set(live.map(\.speaker))
        var slot = 1
        for cluster in speech.keys.sorted(by: { (speech[$0]!, $1) > (speech[$1]!, $0) })
        where labelOf[cluster] == nil {
            while taken.contains("\(labelPrefix) \(slot)") || liveLabels.contains("\(labelPrefix) \(slot)") {
                slot += 1
            }
            labelOf[cluster] = "\(labelPrefix) \(slot)"
            taken.insert("\(labelPrefix) \(slot)")
        }

        return spans.map { SpeakerSegment(speaker: labelOf[$0.cluster]!, start: $0.start, end: $0.end) }
    }

    /// Share of speech time two labelings disagree on, after matching
    /// labels one-to-one by overlap (so the names themselves don't matter).
    /// Sampled every 100 ms where `truth` has exactly one speaker; a moment
    /// the hypothesis leaves unlabeled counts as wrong. For tests and logs.
    static func confusion(truth: [SpeakerSegment], hypothesis: [SpeakerSegment]) -> Double {
        guard let end = truth.map(\.end).max(), end > 0 else { return 0 }
        func at(_ t: TimeInterval, _ segs: [SpeakerSegment]) -> Set<String> {
            Set(segs.lazy.filter { $0.start <= t && $0.end > t }.map(\.speaker))
        }
        // (true speaker, everyone the hypothesis has talking) per sample.
        var frames: [(String, Set<String>)] = []
        var t = 0.05
        while t < end {
            let who = at(t, truth)
            if who.count == 1, let speaker = who.first { frames.append((speaker, at(t, hypothesis))) }
            t += 0.1
        }
        guard !frames.isEmpty else { return 0 }
        var counts: [String: [String: Int]] = [:]
        for (speaker, heard) in frames {
            for h in heard { counts[speaker, default: [:]][h, default: 0] += 1 }
        }
        var pairs: [(truth: String, heard: String, n: Int)] = []
        for (speaker, row) in counts { for (h, n) in row { pairs.append((speaker, h, n)) } }
        pairs.sort { ($0.n, $1.truth, $1.heard) > ($1.n, $0.truth, $0.heard) }
        var match: [String: String] = [:]
        var used = Set<String>()
        for pair in pairs where match[pair.truth] == nil && !used.contains(pair.heard) {
            match[pair.truth] = pair.heard
            used.insert(pair.heard)
        }
        let wrong = frames.filter { speaker, heard in
            guard let want = match[speaker] else { return true }
            return !heard.contains(want)
        }.count
        return Double(wrong) / Double(frames.count)
    }
}

/// The call's audio as the diarizer heard it, kept in a temp file for the
/// final pass: 16 kHz mono Float32, no header. An hour is about 230 MB, so
/// it lives on disk rather than in memory beside the transcription model.
///
/// It is the app's own temp directory, readable only by the user, written
/// during the call and deleted as soon as the pass has read it; leftovers
/// from a crash are removed at the next launch (`removeLeftovers`). Nothing
/// else reads it and it is never uploaded.
///
/// Not thread-safe: the diarizer's queue owns it.
final class SpeakerAudioArchive {
    static let rate: Double = 16_000
    /// Four hours. Past that the pass is skipped and live labels stand.
    static let maxSamples = Int(rate) * 60 * 60 * 4
    private static let prefix = "meetmouse-speakers-"

    let url: URL
    private var handle: FileHandle?
    private(set) var samples = 0
    private(set) var overflowed = false

    var seconds: TimeInterval { Double(samples) / Self.rate }

    init?(directory: URL = FileManager.default.temporaryDirectory) {
        url = directory.appendingPathComponent(Self.prefix + UUID().uuidString + ".pcm")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
    }

    /// Append a chunk. Audio at another rate is brought to 16 kHz by linear
    /// interpolation: the usual sources arrive already decimated, and for
    /// the rest (a 44.1 or 24 kHz microphone) clustering voices does not
    /// need more than that.
    func append(_ chunk: [Float], rate: Double) {
        guard let handle, !overflowed, rate > 0, !chunk.isEmpty else { return }
        let out = rate == Self.rate ? chunk : Self.resample(chunk, from: rate)
        guard samples + out.count <= Self.maxSamples else {
            overflowed = true
            return
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try handle.write(contentsOf: data)
            samples += out.count
        } catch {
            // Disk full or the file went away: without every sample the
            // file's clock no longer matches the call, so it is unusable.
            overflowed = true
        }
    }

    static func resample(_ chunk: [Float], from rate: Double) -> [Float] {
        let count = Int((Double(chunk.count) * Self.rate / rate).rounded())
        guard count > 0 else { return [] }
        let step = rate / Self.rate
        return (0..<count).map { i in
            let position = Double(i) * step
            let index = min(Int(position), chunk.count - 1)
            let next = min(index + 1, chunk.count - 1)
            let fraction = Float(position - Double(index))
            return chunk[index] + (chunk[next] - chunk[index]) * fraction
        }
    }

    /// Stop writing. The file stays until `discard`.
    func close() {
        try? handle?.close()
        handle = nil
    }

    func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    /// Archives a crash or force-quit left behind. Only old ones: the temp
    /// directory is shared with any other running copy of the app (a dev
    /// build beside the installed one), whose call may still be writing.
    static func removeLeftovers(in directory: URL = FileManager.default.temporaryDirectory,
                                olderThan age: TimeInterval = 12 * 3600, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > age {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
