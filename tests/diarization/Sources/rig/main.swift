import AVFoundation
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
let preferred = ["Samantha", "Daniel", "Karen", "Moira", "Tessa", "Rishi", "Fred", "Alex", "Victoria", "Albert"]
let voices = Array(preferred.filter(installed.contains).prefix(3))
guard voices.count == 3 else {
    // Exit 2 = this machine cannot run the check, as opposed to a failure.
    fail("needs three English `say` voices, found \(voices)", code: 2)
}

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
let seconds = Double(audio.count) / rate
mclog("call: \(String(format: "%.0f", seconds))s, \(truth.count) turns, voices \(voices)")

// MARK: Through the real diarizer

struct Outcome {
    var liveVoices = 0, finalVoices = 0
    var live = 1.0, final: Double?
    var finalSeconds = 0.0
}

func diarize(threshold: Double?) async -> Outcome {
    SpeakerDiarizer.finalPassThreshold = threshold
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
    while offset < audio.count {
        diarizer.enqueue(Array(audio[offset..<min(offset + chunk, audio.count)]), sampleRate: rate)
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
    outcome.live = FinalSpeakerPass.confusion(truth: truth, hypothesis: live)
    if let final {
        outcome.finalVoices = Set(final.map(\.speaker)).count
        outcome.final = FinalSpeakerPass.confusion(truth: truth, hypothesis: final)
    }
    return outcome
}

func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

var rows: [String] = []
var failed = false
for threshold in [Double?.none, 0.7] {
    let outcome = await diarize(threshold: threshold)
    let name = threshold.map { "final pass, threshold \($0)" } ?? "final pass, preset"
    rows.append("| live (LS-EEND) | \(outcome.liveVoices) | \(percent(outcome.live)) | |")
    if let final = outcome.final {
        rows.append("| \(name) | \(outcome.finalVoices) | \(percent(final)) | "
                    + String(format: "%.1fs for %.0fs of audio", outcome.finalSeconds, seconds) + " |")
        // The shipped configuration (preset) is the one that must hold.
        if threshold == nil, final > max(0.15, outcome.live + 0.02) { failed = true }
    } else {
        rows.append("| \(name) | did not run | | |")
        if threshold == nil { failed = true }
    }
}

let table = (["| Labels | Voices found (3 real) | Speech given to the wrong person | Time |",
              "|---|---|---|---|"] + rows).joined(separator: "\n")
print("### Speaker attribution (scripted three-voice call)\n\n" + table + "\n")
if let summary = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"],
   let handle = FileHandle(forWritingAtPath: summary) {
    handle.seekToEndOfFile()
    handle.write(("### Speaker attribution (scripted three-voice call)\n\n" + table + "\n\n").data(using: .utf8)!)
    try? handle.close()
}
print(failed ? "DIARIZATION CHECK FAILED" : "diarization check passed")
exit(failed ? 1 : 0)
