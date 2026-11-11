import Accelerate
import Foundation
import FluidAudio

/// One finalized "who spoke when" span, session-relative seconds.
struct SpeakerSegment: Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
}

/// On-device streaming speaker diarization (FluidAudio LS-EEND, CoreML).
///
/// Feed it mono buffers from one audio source; it periodically publishes the
/// full finalized segment list so that source's utterances can be relabeled
/// per speaker ("Them 1/2/…" on the system-audio channel, "Speaker 1/2/…"
/// on a mixed mic stream). Everything runs locally — the CoreML model is
/// downloaded once to Application Support/FluidAudio.
///
/// Saved voice profiles are enrolled before any session audio reaches the
/// model, so known voices come back with their real names instead of slot
/// labels. While the session runs, a short clip of each distinct speaker is
/// collected from the finalized segments — naming a speaker saves that clip
/// as their profile for every future session.
final class SpeakerDiarizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.coach.diarizer", qos: .utility)
    private var diarizer: LSEENDDiarizer?
    /// Audio arriving before the model finishes loading, so segment
    /// timestamps stay aligned with the session start. Capped below.
    private var preload: [(samples: [Float], rate: Double)] = []
    private var preloadSamples = 0
    private let preloadCap = 16_000 * 60 * 5  // ~5 min at 16kHz (post-decimation)
    private var lastProcess = Date.distantPast
    /// Seconds between inference passes. Chunks accumulate regardless, so a
    /// longer beat batches the same compute into fewer CoreML calls — the
    /// only cost is labels landing a beat later, and relabeling is
    /// retroactive anyway.
    private let processInterval: TimeInterval = 2.0
    private var stopped = false

    /// 48kHz → 16kHz before anything is stored or fed (see DiarizerIntake).
    private var intake = DiarizerIntake()

    /// Slot labels for unnamed speakers: "\(labelPrefix) \(index + 1)".
    private let labelPrefix: String
    /// Saved voices to enroll once the model is ready.
    private let profiles: [VoiceProfile]

    // MARK: Voice-clip capture (all on `queue`)

    /// Rolling window of recent session audio, session-relative seconds.
    /// Only needs to cover segment-finalization latency, not the session.
    private var ring: [(start: TimeInterval, rate: Double, samples: [Float])] = []
    private var fedSeconds: TimeInterval = 0
    private let ringSeconds: TimeInterval = 45

    private struct ClipBuffer {
        var samples: [Float] = []
        var rate: Double = 0
        /// Segment time already harvested into `samples`.
        var consumedUntil: TimeInterval = 0
        var isFull: Bool {
            rate > 0 && Double(samples.count) / rate >= VoiceProfileStore.maxClipSeconds
        }
    }
    private var clips: [Int: ClipBuffer] = [:]
    /// Names given this session whose clips may not be viable yet — saves
    /// fire as clips cross the minimum, with a final refresh at stop.
    private var pendingSaves = PendingProfileSaves()
    /// Display label per slot at last publish — lets rename/clip lookups
    /// keep working after stop() releases the model.
    private var labelBySlot: [Int: String] = [:]
    /// Fingerprint of the last published finalized-segment set. Most ticks
    /// finalize nothing new; skipping those publishes saves the consumer's
    /// full-transcript relabel pass.
    private var publishedCount = -1
    private var publishedLastEnd: Float = -1

    var onSegments: (@Sendable ([SpeakerSegment]) -> Void)?

    init(labelPrefix: String = "Speaker", profiles: [VoiceProfile] = []) {
        self.labelPrefix = labelPrefix
        self.profiles = profiles
    }

    func start() {
        // Intel: LS-EEND crashes the process in CoreML's x86 CPU kernels
        // (see PlatformSupport). Marking the diarizer stopped makes enqueue
        // drop audio instead of accumulating a preload no model will read.
        guard PlatformSupport.neuralModelsSupported else {
            mclog("[Diarizer:\(labelPrefix)] Skipped — diarization unavailable on Intel Macs")
            queue.async { self.stopped = true }
            return
        }
        Task {
            do {
                // .dihard3: in-the-wild conversations — right for room audio
                // (in-person meetings, phone-on-speaker near the Mac) and
                // holds up on compressed meeting-app streams.
                let d = try await LSEENDDiarizer(variant: .dihard3)
                self.queue.async {
                    guard !self.stopped else { return }
                    self.enroll(into: d)
                    self.diarizer = d
                    for chunk in self.preload {
                        try? d.addAudio(chunk.samples, sourceSampleRate: chunk.rate)
                    }
                    self.preload = []
                    mclog("[Diarizer:\(self.labelPrefix)] Ready (LS-EEND dihard3)")
                }
            } catch {
                mclog("[Diarizer:\(self.labelPrefix)] Unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Enqueue mono float samples from the source tap. Safe from any thread.
    func enqueue(_ samples: [Float], sampleRate: Double) {
        queue.async {
            guard !self.stopped else { return }
            guard let (samples, rate) = self.intake.audio(samples, sampleRate: sampleRate) else {
                return  // FIR warm-up
            }
            self.ingest(samples, rate: rate)
        }
    }

    /// Advance the diarizer's clock across a stretch where capture delivered
    /// nothing (an audio restart). Segment times count fed audio, so a gap
    /// that isn't backfilled shifts every later segment early.
    func enqueueSilence(seconds: TimeInterval) {
        queue.async {
            guard !self.stopped else { return }
            let plan = self.intake.silence(seconds: seconds)
            guard plan.samples > 0 else { return }
            let second = [Float](repeating: 0, count: plan.chunk)
            for i in 0..<plan.fullChunks {
                self.feed(second, rate: plan.rate)
                // A long gap would otherwise queue all of it inside the
                // model before one inference pass.
                if (i + 1) % 30 == 0 { _ = try? self.diarizer?.process() }
            }
            if plan.remainder > 0 {
                self.feed([Float](second.prefix(plan.remainder)), rate: plan.rate)
            }
            self.processIfDue()
        }
    }

    /// Model-ready samples (already decimated when the source needed it):
    /// ring, model, throttled inference. Queue only.
    private func ingest(_ samples: [Float], rate: Double) {
        guard feed(samples, rate: rate) else { return }
        processIfDue()
    }

    /// Ring + model (or the preload while the model is loading). False when
    /// the model did not take the audio.
    @discardableResult
    private func feed(_ samples: [Float], rate: Double) -> Bool {
        ringAppend(samples, rate: rate)
        guard let d = diarizer else {
            if preloadSamples < preloadCap {
                preload.append((samples, rate))
                preloadSamples += samples.count
            }
            return false
        }
        do {
            try d.addAudio(samples, sourceSampleRate: rate)
            return true
        } catch {
            mclog("[Diarizer:\(labelPrefix)] addAudio failed: \(error)")
            return false
        }
    }

    /// Throttled inference + timeline read.
    private func processIfDue() {
        guard let d = diarizer,
              Date().timeIntervalSince(lastProcess) > processInterval else { return }
        lastProcess = Date()
        do {
            _ = try d.process()
        } catch {
            mclog("[Diarizer:\(labelPrefix)] process failed: \(error)")
        }
        publish(from: d)
    }

    func stop() {
        queue.async {
            self.stopped = true
            if let d = self.diarizer {
                try? d.finalizeSession()
                self.publish(from: d)
            }
            // Speakers named this session get their profile refreshed with
            // the fullest clip the session collected (final harvest above).
            self.flushProfileSaves(final: true)
            // Keep clips + labelBySlot: naming a speaker from the
            // post-session view still needs them.
            self.diarizer = nil
            self.preload = []
            self.ring = []
        }
    }

    /// Rename the speaker currently displayed as `label`. Renames the live
    /// timeline slot (future publishes carry the name), saves the collected
    /// voice clip as a profile for future sessions, and republishes so the
    /// whole transcript relabels. Works after stop() for the profile part.
    func rename(_ label: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        queue.async {
            guard let slot = self.labelBySlot.first(where: { $0.value == label })?.key
                    ?? self.slotFromLabel(label) else {
                mclog("[Diarizer:\(self.labelPrefix)] rename: unknown label \(label)")
                return
            }
            // Naming before the clip is viable keeps the name pending — the
            // save fires from publish() once enough speech is collected
            // (early renames used to silently save no profile). After stop
            // the clip is as full as it gets, so refresh immediately.
            self.pendingSaves.name(slot: slot, as: name)
            self.flushProfileSaves(final: self.stopped)
            let collected = self.clips[slot].map {
                $0.rate > 0 ? Double($0.samples.count) / $0.rate : 0
            } ?? 0
            if collected < VoiceProfileStore.minClipSeconds {
                mclog("[Diarizer:\(self.labelPrefix)] rename: clip for \(label) at "
                      + String(format: "%.1f", collected) + "s — profile save pending")
            }
            self.labelBySlot[slot] = name
            if let d = self.diarizer {
                _ = d.timeline.upsertSpeaker(named: name, atIndex: slot)
                self.publishedCount = -1   // force: same segments, new labels
                self.publish(from: d)
            }
        }
    }

    /// Whether this diarizer has ever published `label` (so a rename can be
    /// routed to the right channel's diarizer).
    func knows(_ label: String, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            completion(self.labelBySlot.values.contains(label) || self.slotFromLabel(label) != nil)
        }
    }

    // MARK: - Enrollment (on queue)

    /// Feed each saved voice through the model before session audio so known
    /// people surface by name. One slot is always left free for a stranger.
    private func enroll(into d: LSEENDDiarizer) {
        guard !profiles.isEmpty else { return }
        let capacity = max(1, (d.numSpeakers ?? 4) - 1)
        if profiles.count > capacity {
            let dropped = profiles.dropFirst(capacity).map(\.name).joined(separator: ", ")
            mclog("[Diarizer:\(labelPrefix)] Enrollment capacity \(capacity) — not enrolling: \(dropped)")
        }
        for p in profiles.prefix(capacity) {
            do {
                if let speaker = try d.enrollSpeaker(withAudio: p.samples,
                                                     sourceSampleRate: p.sampleRate,
                                                     named: p.name) {
                    labelBySlot[speaker.index] = p.name
                    mclog("[Diarizer:\(labelPrefix)] Enrolled \(p.name) at slot \(speaker.index)")
                } else {
                    mclog("[Diarizer:\(labelPrefix)] Enrollment produced no speaker for \(p.name)")
                }
            } catch {
                mclog("[Diarizer:\(labelPrefix)] Enroll \(p.name) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Publish + clip harvest (on queue)

    private func publish(from d: LSEENDDiarizer) {
        // Cheap no-change check before any array building.
        var count = 0
        var lastEnd: Float = -1
        for (_, speaker) in d.timeline.speakers {
            count += speaker.finalizedSegmentCount
            if let end = speaker.finalizedSegments.last?.endTime {
                lastEnd = max(lastEnd, end)
            }
        }
        guard count != publishedCount || lastEnd != publishedLastEnd else { return }
        publishedCount = count
        publishedLastEnd = lastEnd

        var segments: [SpeakerSegment] = []
        for (slot, speaker) in d.timeline.speakers {
            let label = speaker.name ?? "\(labelPrefix) \(speaker.index + 1)"
            labelBySlot[slot] = label
            if clips[slot]?.isFull != true {
                // A diarized segment can overlap another person's speech. The
                // source is still mixed audio, so never save those samples as
                // a clean example of this person's voice. Include tentative
                // interruptions: another speaker may still be mid-turn.
                let otherSpeech = d.timeline.speakers
                    .filter { $0.key != slot }
                    .flatMap { $0.value.finalizedSegments + $0.value.tentativeSegments }
                    .compactMap { seg -> Range<TimeInterval>? in
                        let start = TimeInterval(seg.startTime), end = TimeInterval(seg.endTime)
                        return end > start ? start..<end : nil
                    }
                harvestClip(slot: slot, from: speaker, excluding: otherSpeech)
            }
            for seg in speaker.finalizedSegments {
                segments.append(SpeakerSegment(
                    speaker: label,
                    start: TimeInterval(seg.startTime),
                    end: TimeInterval(seg.endTime)
                ))
            }
        }
        flushProfileSaves(final: false)
        guard !segments.isEmpty else { return }
        segments.sort { $0.start < $1.start }
        onSegments?(segments)
    }

    /// Write any name whose clip just became viable (or, at session end,
    /// grew past what was last written) to the profile store.
    private func flushProfileSaves(final: Bool) {
        let seconds = clips.mapValues { $0.rate > 0 ? Double($0.samples.count) / $0.rate : 0 }
        for save in pendingSaves.due(clipSeconds: seconds,
                                     minSeconds: VoiceProfileStore.minClipSeconds,
                                     final: final) {
            guard let clip = clips[save.slot] else { continue }
            VoiceProfileStore.save(name: save.name, samples: clip.samples, sampleRate: clip.rate)
        }
    }

    /// Top up this speaker's voice clip from newly finalized segments still
    /// covered by the audio ring.
    private func harvestClip(slot: Int, from speaker: DiarizerSpeaker,
                             excluding otherSpeech: [Range<TimeInterval>]) {
        var clip = clips[slot] ?? ClipBuffer()
        defer { clips[slot] = clip }
        guard !clip.isFull else { return }

        for seg in speaker.finalizedSegments {
            let start = max(TimeInterval(seg.startTime), clip.consumedUntil)
            let end = TimeInterval(seg.endTime)
            guard end > start else { continue }
            let solo = VoiceClipSelection.soloRanges(start: start, end: end,
                                                     excluding: otherSpeech)
            for range in solo {
                let (samples, rate) = ringExtract(from: range.lowerBound, to: range.upperBound)
                guard !samples.isEmpty, rate > 0 else { continue }
                // Advance only after extraction: ranges ahead of the ring
                // remain eligible on the next publish.
                clip.consumedUntil = range.upperBound
                if clip.rate <= 0 { clip.rate = rate }
                guard rate == clip.rate else { continue }
                let remaining = max(0, Int(VoiceProfileStore.maxClipSeconds * rate) - clip.samples.count)
                clip.samples.append(contentsOf: samples.prefix(remaining))
                if clip.isFull {
                    return
                }
            }
        }
    }

    // MARK: - Audio ring (on queue)

    private func ringAppend(_ samples: [Float], rate: Double) {
        guard rate > 0, !samples.isEmpty else { return }
        ring.append((start: fedSeconds, rate: rate, samples: samples))
        fedSeconds += Double(samples.count) / rate
        let cutoff = fedSeconds - ringSeconds
        while let first = ring.first,
              first.start + Double(first.samples.count) / first.rate < cutoff {
            ring.removeFirst()
        }
    }

    /// Copy session audio for [from, to) out of the ring. Returns the chunk
    /// rate; spans predating the ring come back partial or empty.
    private func ringExtract(from: TimeInterval, to: TimeInterval) -> ([Float], Double) {
        var out: [Float] = []
        var rate: Double = 0
        for chunk in ring {
            let chunkEnd = chunk.start + Double(chunk.samples.count) / chunk.rate
            let s = max(from, chunk.start), e = min(to, chunkEnd)
            guard e > s else { continue }
            if rate <= 0 { rate = chunk.rate }
            guard chunk.rate == rate else { continue }
            let lo = Int((s - chunk.start) * chunk.rate)
            let hi = min(chunk.samples.count, Int((e - chunk.start) * chunk.rate))
            guard hi > lo else { continue }
            out.append(contentsOf: chunk.samples[lo..<hi])
        }
        return (out, rate)
    }

    /// "Them 2" → slot 1 when the slot was never published (early rename).
    /// The BARE channel label ("Them" — what the transcript shows before
    /// the diarizer's first publish) is slot 0: renaming it used to vanish
    /// silently, so the user's first, most natural tag saved no profile
    /// (seen live 2026-08-04 — "Them" → Dana was a no-op and she had to
    /// be named again as "Them 1").
    private func slotFromLabel(_ label: String) -> Int? {
        if label == labelPrefix { return 0 }
        guard label.hasPrefix(labelPrefix + " "),
              let n = Int(label.dropFirst(labelPrefix.count + 1)), n >= 1 else { return nil }
        return n - 1
    }
}
