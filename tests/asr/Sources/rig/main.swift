import AVFoundation
import FluidAudio
import Foundation

// Feeds a playlist of audio files (with silence gaps) through the REAL
// ParakeetPipeline, emitting machine-readable UTT/PARTIAL lines.
//
// Usage: rig <playlist.json> <normal|cut>
//   normal — trailing 2.5s silence, then stop() (silence-gap commit path)
//   cut    — stop() immediately after the last sample (tail-flush path)
//
// Environment:
//   RIG_CLOCK=audio     audio clock instead of real time: a virtual clock
//                       advances by each fed buffer's duration, tick() runs
//                       after every 1.0s of fed audio, nothing sleeps. Same
//                       audio => same commits, and much faster than real
//                       time. Default (unset/"real"): real time, wall-clock
//                       ticks, exactly what the blocking gate has always run.
//   RIG_VOICE_FLOOR     pipeline voice floor (default 0.006, the mic's;
//                       the app's Them channel uses 0.002)
//   RIG_COMMIT_SILENCE  pipeline silence gap in seconds (default 0.9, the
//                       mic's; the Them channel uses 2.0)
//   RIG_NOISE_RMS       mix fixed-seed white noise at this RMS into every
//                       fed buffer, gap silence included (default: none)
//   RIG_ASR=v3, RIG_LANGUAGE=<code>   model / language hint

struct Item: Decodable {
    let file: String        // empty string = pure silence segment
    let gapAfter: Double    // seconds of zeros appended after the file
}

/// Lock-protected virtual time for the audio-clock mode. Kept in whole
/// microseconds so 10 × 100 ms is exactly one second (no float drift in
/// tick placement).
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin: Date
    private var micros: Int64 = 0
    init(origin: Date) { self.origin = origin }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return origin.addingTimeInterval(Double(micros) / 1_000_000)
    }
    func advance(micros delta: Int64) {
        lock.lock()
        micros += delta
        lock.unlock()
    }
}

/// Deterministic white noise (SplitMix64, fixed seed), uniform in ±a with
/// a = rms·√3 so the added RMS is `rms`. Used only from the rig's feed loop.
final class NoiseMixer {
    private var state: UInt64 = 0x5EED_1234_ABCD_0001
    private let amplitude: Float
    init(rms: Float) { amplitude = rms * Float(3.0).squareRoot() }

    private func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Adds noise in place to every channel of a float buffer.
    func mix(into buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let stride = buffer.stride
        for c in 0..<Int(buffer.format.channelCount) {
            let ch = channels[c]
            for i in 0..<n {
                let unit = Float(next() >> 40) / Float(1 << 24)     // [0, 1)
                ch[i * stride] += (unit * 2 - 1) * amplitude
            }
        }
    }
}

guard CommandLine.arguments.count > 1 else {
    print("Usage: rig <playlist.json> [normal|cut]")
    exit(2)
}
let playlistPath = CommandLine.arguments[1]
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "normal"
let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: playlistPath)))

let env = ProcessInfo.processInfo.environment
let audioClock = env["RIG_CLOCK"] == "audio"
let sessionStart = Date()
let clock = VirtualClock(origin: sessionStart)
let nowFn: @Sendable () -> Date = audioClock ? { clock.now() } : { Date() }
let voiceFloor = env["RIG_VOICE_FLOOR"].flatMap { Float($0) } ?? 0.006
let commitSilence = env["RIG_COMMIT_SILENCE"].flatMap { Double($0) } ?? 0.9
let noise: NoiseMixer? = env["RIG_NOISE_RMS"].flatMap { Float($0) }
    .flatMap { $0 > 0 ? NoiseMixer(rms: $0) : nil }

let useV3 = env["RIG_ASR"] == "v3"
let modelVersion: AsrModelVersion = useV3 ? .v3 : .v2
let languageHint = env["RIG_LANGUAGE"].flatMap(Language.init(rawValue:))
let pipeline = ParakeetPipeline(speaker: "Meeting", sessionStart: sessionStart,
                                voiceFloor: voiceFloor, commitSilence: commitSilence,
                                modelVersion: modelVersion, languageHint: languageHint,
                                now: nowFn)
func stamp() -> String {
    String(format: "%.2f", nowFn().timeIntervalSince(sessionStart))
}
var utteranceCount = 0
pipeline.onUtterance = { u in
    utteranceCount += 1
    print("UTT\t\(stamp())\t\(String(format: "%.2f", u.t))\t\(String(format: "%.2f", u.endT))\t\(u.text)")
}
pipeline.onPartial = { p in
    print("PARTIAL\t\(stamp())\t\(p)")
}

guard await ParakeetEngine.shared.ensureLoaded(version: modelVersion) else {
    print("FATAL\tengine failed to load")
    exit(1)
}
print("CONFIG\tclock=\(audioClock ? "audio" : "real")\tfloor=\(voiceFloor)"
      + "\tcommitSilence=\(commitSilence)\tnoise=\(env["RIG_NOISE_RMS"] ?? "0")")

/// Feeds buffers in either clock mode. Only the top-level feed loop uses
/// it, one call at a time.
final class Feeder: @unchecked Sendable {
    private let pipeline: ParakeetPipeline
    private let clock: VirtualClock
    private let audioClock: Bool
    private let noise: NoiseMixer?
    private let tickMicros: Int64 = 1_000_000
    private var sinceTick: Int64 = 0     // audio fed since the last manual tick

    init(pipeline: ParakeetPipeline, clock: VirtualClock, audioClock: Bool, noise: NoiseMixer?) {
        self.pipeline = pipeline
        self.clock = clock
        self.audioClock = audioClock
        self.noise = noise
    }

    func start() {
        if audioClock {
            pipeline.startManual()
        } else {
            pipeline.start()
        }
    }

    /// Real time: append, then sleep 100 ms (the pipeline's own loop
    /// ticks). Audio clock: advance virtual time by the buffer's duration
    /// first — in real time a buffer reaches append() only after its audio
    /// played, so its voice stamp is its END — then append, then tick once
    /// per full second of fed audio.
    func feed(_ buf: AVAudioPCMBuffer) async throws {
        noise?.mix(into: buf)
        if audioClock {
            let micros = Int64((Double(buf.frameLength) / buf.format.sampleRate * 1_000_000).rounded())
            clock.advance(micros: micros)
            pipeline.append(buf)
            await tickIfDue(after: micros)
        } else {
            pipeline.append(buf)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The trailing wait with nothing fed, so silence commits can land.
    func idle(seconds: Double) async throws {
        if audioClock {
            for _ in 0..<Int((seconds * 10).rounded()) {
                clock.advance(micros: 100_000)
                await tickIfDue(after: 100_000)
            }
        } else {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    func finish() async throws {
        if audioClock {
            // Awaited flush: every utterance is printed when this returns.
            await pipeline.stopAndFlush()
        } else {
            pipeline.stop()
            // Give the async tail flush time to land.
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }

    private func tickIfDue(after micros: Int64) async {
        sinceTick += micros
        while sinceTick >= tickMicros {
            sinceTick -= tickMicros
            await pipeline.tick()
        }
    }
}

let feeder = Feeder(pipeline: pipeline, clock: clock, audioClock: audioClock, noise: noise)
feeder.start()

for item in items {
    if !item.file.isEmpty {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: item.file))
        let fmt = f.processingFormat
        let chunkFrames = AVAudioFrameCount(fmt.sampleRate / 10)   // 100 ms
        while f.framePosition < f.length {
            let n = min(chunkFrames, AVAudioFrameCount(f.length - f.framePosition))
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { break }
            try f.read(into: buf, frameCount: n)
            try await feeder.feed(buf)
        }
        print("FED\t\(stamp())\t\(item.file)")
    }
    if item.gapAfter > 0 {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        let chunkFrames = AVAudioFrameCount(2205)
        for _ in 0..<Int(item.gapAfter * 10) {
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames) else { break }
            buf.frameLength = chunkFrames   // zero-initialized = silence
            try await feeder.feed(buf)
        }
    }
}

if mode == "cut" {
    print("STOP\t\(stamp())\tcut: stopping mid-stream")
} else {
    try await feeder.idle(seconds: 2.5)
}
try await feeder.finish()
print("DONE\t\(utteranceCount)")
