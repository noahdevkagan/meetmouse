import AVFoundation
import FluidAudio
import Foundation

// Who-said-what check on a scripted three-person call.
//
// Each line is rendered with a different macOS voice (`say`), so the truth
// is known exactly. The call goes through the app's real SpeakerDiarizer:
// the live labels (LS-EEND, streaming) and then the whole-call final pass
// (offline clustering) that runs at Stop. Both are scored as the share of
// speech time attributed to the wrong person.
//
// Synthetic voices are cleaner and more distinct than a real call, so the
// numbers are a floor, not a forecast. What the rig proves is that the
// final pass runs end to end on this machine, keeps the live names, and is
// not worse than the live labels.

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write("diarization rig: \(message)\n".data(using: .utf8)!)
    exit(code)
}

@discardableResult
func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: Voices

// `say -v ?` lines read "Name   en_US   # sample sentence".
let installed = Set(run("/usr/bin/say", ["-v", "?"]).output.split(separator: "\n").compactMap { line -> String? in
    guard let locale = line.range(of: #"\s+[a-z]{2}_[A-Z]{2}\s"#, options: .regularExpression) else { return nil }
    return String(line[..<locale.lowerBound])
})
let preferred = ["Samantha", "Daniel", "Karen", "Moira", "Tessa", "Rishi", "Alex", "Victoria",
                 "Fred", "Kathy", "Ralph", "Albert", "Junior"]

// MARK: Script (made-up people and project)

let people = ["Ilse", "Bram", "Noor"]
let script: [(Int, String)] = [
    (0, "Thanks for joining. I want to settle the launch date for the reporting dashboard today."),
    (1, "Sure. From the engineering side we are about two weeks out, assuming the export bug is fixed."),
    (2, "Two weeks is tight for us. The customer webinar is already scheduled for the ninth."),
    (0, "Okay."),
    (1, "The export bug is the real risk. It only shows up on accounts with more than fifty thousand rows."),
    (2, "How many customers is that?"),
    (1, "About thirty, but they are the largest ones."),
    (0, "Then we cannot ship without it. Noor, could the webinar move by a week?"),
    (2, "I can ask, but I would rather keep the date and demo a smaller account."),
    (1, "That works for me. A demo on a small account will not hit the bug at all."),
    (0, "Good. So the webinar stays on the ninth, and the full rollout waits for the fix."),
    (2, "Yes."),
    (1, "I will have an estimate for the fix by Thursday."),
    (0, "Please send it to both of us. What about the pricing page?"),
    (2, "The pricing page is ready. Legal approved the wording yesterday afternoon."),
    (1, "Do we still need the usage meter on that page?"),
    (2, "Not for launch. We agreed to add it in the second release."),
    (0, "Right. I remember that."),
    (1, "Then engineering has nothing left on pricing. I will close those tickets today."),
    (2, "One more thing from my side. Support needs training before any customer sees this."),
    (0, "How long does the training take?"),
    (2, "Two sessions of one hour each. I can run them next Tuesday and Wednesday."),
    (1, "I would like one engineer in each session to answer the technical questions."),
    (2, "That would help a lot. Thank you."),
    (0, "Let me repeat the plan. Bram sends the estimate on Thursday. Noor runs training next week."),
    (1, "Correct."),
    (0, "And I will tell the leadership team that the full rollout depends on the export fix."),
    (2, "Should I prepare a short summary for them as well?"),
    (0, "Yes please, one page is enough."),
    (1, "Before we finish, the staging server will be down on Friday morning for an upgrade."),
    (2, "For how long?"),
    (1, "Roughly three hours. It should be back before noon."),
    (0, "That is fine. Nobody is demoing on Friday."),
    (2, "I have a partner call on Friday, but it does not need staging."),
    (0, "Great. Anything else?"),
    (1, "Nothing from me."),
    (2, "No, that covers it."),
    (0, "Thank you both. We will meet again next Monday at the same time."),
]

// MARK: Render

let rate = 16_000.0
let work = FileManager.default.temporaryDirectory.appendingPathComponent("meetmouse-diarization-rig-audio")
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

func render(_ text: String, voice: String, index: Int) -> [Float] {
    let file = work.appendingPathComponent("\(index)-\(voice).wav")
    if !FileManager.default.fileExists(atPath: file.path) {
        let status = run("/usr/bin/say", ["-v", voice, "-o", file.path,
                                          "--data-format=LEI16@16000", text]).status
        guard status == 0 else { fail("say failed for voice \(voice)", code: 2) }
    }
    guard let audio = try? AVAudioFile(forReading: file),
          let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                        frameCapacity: AVAudioFrameCount(audio.length)),
          (try? audio.read(into: buffer)) != nil,
          let channel = buffer.floatChannelData?[0] else {
        fail("could not read \(file.lastPathComponent)", code: 2)
    }
    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    // Trim the silence `say` pads with, so the truth is the speech itself.
    guard let first = samples.firstIndex(where: { abs($0) > 0.01 }),
          let last = samples.lastIndex(where: { abs($0) > 0.01 }) else { return [] }
    return Array(samples[first...last])
}

// A voice that is listed but not downloaded renders with the system voice,
// which would put the same voice behind two "people". Keep only voices whose
// rendering of one probe sentence differs from every voice already chosen.
let probe = "The quarterly report is due on the fourteenth of March."
var voices: [String] = []
var probes: [[Float]] = []
func sameVoice(_ a: [Float], _ b: [Float]) -> Bool {
    guard abs(a.count - b.count) < 800 else { return false }
    let n = min(a.count, b.count)
    guard n > 0 else { return true }
    var difference: Float = 0
    for i in 0..<n { difference += abs(a[i] - b[i]) }
    return difference / Float(n) < 0.005
}
for (index, voice) in preferred.enumerated() where installed.contains(voice) && voices.count < 3 {
    let sample = render(probe, voice: voice, index: 1000 + index)
    guard !sample.isEmpty, !probes.contains(where: { sameVoice($0, sample) }) else {
        mclog("voice \(voice) renders like one already chosen; skipped")
        continue
    }
    voices.append(voice)
    probes.append(sample)
}
guard voices.count == 3 else {
    // Exit 2 = this machine cannot run the check, as opposed to a failure.
    fail("needs three distinct English `say` voices, found \(voices)", code: 2)
}

struct Call {
    let name: String
    let audio: [Float]
    let truth: [SpeakerSegment]
    var seconds: Double { Double(audio.count) / rate }
    var people: Int { Set(truth.map(\.speaker)).count }
}

var audio: [Float] = []
var truth: [SpeakerSegment] = []
for (index, line) in script.enumerated() {
    let speech = render(line.1, voice: voices[line.0], index: index)
    guard !speech.isEmpty else { continue }
    // Mostly a short pause between turns; every fourth handoff is immediate.
    let gap = index % 4 == 3 ? 0.05 : 0.35
    audio.append(contentsOf: [Float](repeating: 0, count: Int(gap * rate)))
    let start = Double(audio.count) / rate
    audio.append(contentsOf: speech)
    truth.append(SpeakerSegment(speaker: people[line.0], start: start, end: Double(audio.count) / rate))
}
var calls = [Call(name: "scripted, 3 `say` voices", audio: audio, truth: truth)]
mclog("scripted call: \(String(format: "%.0f", calls[0].seconds))s, \(truth.count) turns, voices \(voices)")

// MARK: Real meetings (AMI corpus, CC BY 4.0)
//
// Four people in a room, recorded on headset microphones and mixed: real
// voices, interruptions and backchannels, with hand-made "who spoke when"
// annotations. The first minutes of three test-set meetings. Downloaded on
// demand and never committed; set DIARIZATION_REAL=0 to skip.

func download(_ urls: [String], to file: URL) -> Bool {
    if FileManager.default.fileExists(atPath: file.path) { return true }
    for url in urls {
        let status = run("/usr/bin/curl", ["-sfL", "--max-time", "300", "-o", file.path, url]).status
        if status == 0 { return true }
        try? FileManager.default.removeItem(at: file)
    }
    return false
}

func decode(_ file: URL, seconds limit: Double) -> [Float]? {
    guard let input = try? AVAudioFile(forReading: file),
          let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                     channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: input.processingFormat, to: target) else { return nil }
    let wanted = AVAudioFrameCount(min(Double(input.length), limit * input.processingFormat.sampleRate))
    guard let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: wanted),
          (try? input.read(into: source, frameCount: wanted)) != nil,
          let output = AVAudioPCMBuffer(pcmFormat: target,
                                        frameCapacity: AVAudioFrameCount(limit * rate) + 1024) else { return nil }
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return source
    }
    guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
}

if ProcessInfo.processInfo.environment["DIARIZATION_REAL"] != "0" {
    let minutes = 8.0
    for meeting in ["ES2004a", "IS1009a", "TS3003a"] {
        let wav = work.appendingPathComponent("\(meeting).wav")
        let rttm = work.appendingPathComponent("\(meeting).rttm")
        let base = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/\(meeting)/audio/\(meeting)"
        guard download(["\(base).Mix-Headset.wav",
                        "https://huggingface.co/datasets/FluidInference/ami-corpus-mirror/resolve/main/sdm/\(meeting).Mix-Headset.wav"],
                       to: wav),
              download(["https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/test/\(meeting).rttm"],
                       to: rttm),
              let samples = decode(wav, seconds: minutes * 60),
              let annotation = try? String(contentsOf: rttm, encoding: .utf8) else {
            mclog("real meeting \(meeting): could not download or read; skipped")
            continue
        }
        // RTTM: SPEAKER <file> 1 <start> <duration> <NA> <NA> <speaker> ...
        let spoken = annotation.split(separator: "\n").compactMap { line -> SpeakerSegment? in
            let fields = line.split(separator: " ")
            guard fields.count >= 8, fields[0] == "SPEAKER",
                  let start = Double(fields[3]), let length = Double(fields[4]),
                  start < minutes * 60 else { return nil }
            return SpeakerSegment(speaker: String(fields[7]), start: start,
                                  end: min(start + length, minutes * 60))
        }
        guard !spoken.isEmpty else { continue }
        calls.append(Call(name: "real meeting \(meeting), first \(Int(minutes)) min", audio: samples, truth: spoken))
        mclog("real meeting \(meeting): \(samples.count / Int(rate))s, \(spoken.count) segments")
    }
}


// MARK: Through the real diarizer

struct Outcome {
    var liveVoices = 0, finalVoices = 0
    var live = 1.0, final: Double?
    var finalSeconds = 0.0
}

func diarize(_ call: Call, variant: LSEENDVariant, finalPass: Bool) async -> Outcome {
    SpeakerDiarizer.liveVariant = variant
    UserDefaults.standard.set(finalPass, forKey: FinalSpeakerPass.enabledKey)
    let diarizer = SpeakerDiarizer(labelPrefix: "Them")
    let latest = Box<[SpeakerSegment]>([])
    diarizer.onSegments = { latest.set($0) }
    diarizer.start()
    // First run downloads the live model.
    let deadline = Date().addingTimeInterval(600)
    while await !diarizer.isReady() {
        guard Date() < deadline else { fail("live model did not load", code: 2) }
        try? await Task.sleep(for: .milliseconds(250))
    }
    let chunk = Int(rate)
    var offset = 0
    while offset < call.audio.count {
        diarizer.enqueue(Array(call.audio[offset..<min(offset + chunk, call.audio.count)]), sampleRate: rate)
        offset += chunk
        try? await Task.sleep(for: .milliseconds(5))
    }
    diarizer.stop()
    let started = Date()
    let final = await diarizer.finalSegments()
    var outcome = Outcome()
    outcome.finalSeconds = Date().timeIntervalSince(started)
    let live = latest.get()
    outcome.liveVoices = Set(live.map(\.speaker)).count
    outcome.live = FinalSpeakerPass.confusion(truth: call.truth, hypothesis: live)
    if let final {
        outcome.finalVoices = Set(final.map(\.speaker)).count
        outcome.final = FinalSpeakerPass.confusion(truth: call.truth, hypothesis: final)
    }
    return outcome
}

func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

// Per call: the shipped live model with the final pass, then the other live
// variants alone. Only the scripted call's shipped row can fail the check.
var rows: [String] = []
var failed = false
for (index, call) in calls.enumerated() {
    let shipped = await diarize(call, variant: .callhome, finalPass: true)
    rows.append("| \(call.name) | live, callhome (shipped) | \(shipped.liveVoices) of \(call.people) | \(percent(shipped.live)) | |")
    if let final = shipped.final {
        rows.append("| | final pass | \(shipped.finalVoices) of \(call.people) | \(percent(final)) | "
                    + String(format: "%.0fs for %.0fs of audio", shipped.finalSeconds, call.seconds) + " |")
    } else {
        rows.append("| | final pass | did not run | | |")
        if index == 0 { failed = true }
    }
    for (name, variant) in [("dihard3", LSEENDVariant.dihard3), ("ami", .ami)] {
        let other = await diarize(call, variant: variant, finalPass: false)
        rows.append("| | live, \(name) | \(other.liveVoices) of \(call.people) | \(percent(other.live)) | |")
    }
}

let title = "### Speaker attribution: share of speech given to the wrong person"
let table = (["| Call | Labels | Voices found | Wrong person | Time |", "|---|---|---|---|---|"] + rows)
    .joined(separator: "\n")
print(title + "\n\n" + table + "\n")
if let summary = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"],
   let handle = FileHandle(forWritingAtPath: summary) {
    handle.seekToEndOfFile()
    handle.write((title + "\n\n" + table + "\n\n").data(using: .utf8)!)
    try? handle.close()
}
print(failed ? "DIARIZATION CHECK FAILED" : "diarization check passed")
exit(failed ? 1 : 0)
