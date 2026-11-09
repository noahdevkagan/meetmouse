import Foundation

// Notes-accuracy bench (informational, never gates a push).
//
// Builds the REAL post-call notes prompt (PromptBuilder.swift, compiled in)
// for a made-up 50-minute meeting whose key decisions sit in the middle,
// runs it on a local Ollama model, and scores the notes:
//   - planted facts caught (6 mid-meeting decisions + 1 from the tail)
//   - invented deadlines in NEXT STEPS (a timeframe not said in the meeting)
//
// Modes compare what each notes path sends:
//   before   — the pre-2026-11-08 Regenerate: 32K trim, empty context
//   standard — <32 GB Macs today: 32K trim, saved goal and guests
//   roomy    — >=32 GB Macs today: 72K window, saved goal and guests
//
// One run per mode at the app's temperature (0.3): read movement across
// commits, not a single number.

// Stub for the one app symbol PromptBuilder needs outside its own file.
enum ModelMemory { static var physicalRAMGB: Int { 32 } }

let env = ProcessInfo.processInfo.environment
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let model = env["NOTES_MODEL"] ?? "qwen3.5:9b"
let port = env["OLLAMA_PORT"] ?? "11434"
let modes = (env["NOTES_MODES"] ?? "before,standard,roomy").split(separator: ",").map(String.init)
let transcript = try String(contentsOf: dir.appendingPathComponent("meeting.txt"), encoding: .utf8)

var context = PreCallContext()
context.meetingGoal = "Agree launch plan and pricing for Lanternly Teams"
context.participants = [.init(name: "Marta", role: "Head of Operations, Fernbrook")]

struct Fact { let id: String; let pattern: String }
let facts = [
    Fact(id: "M1 $14/seat, 5-seat minimum", pattern: #"\$?14\b|fourteen"#),
    Fact(id: "M2 launch moved to March 24", pattern: #"\b24(th)?\b|twenty.?fourth"#),
    Fact(id: "M3 Teodor owns migration", pattern: #"Teodor"#),
    Fact(id: "M4 contractor cap $18k", pattern: #"\b18\b|18,000|18k|eighteen"#),
    Fact(id: "M5 Android beta paused to Q3", pattern: #"Android"#),
    Fact(id: "M6 90-day retention open", pattern: #"\b90\b|ninety"#),
    Fact(id: "T1 send launch summary", pattern: #"summary"#),
]

/// Timeframes in NEXT STEPS that the meeting never said are invented.
let deadlinePattern = #"(by|before|within|until|in) (the )?(next )?(end of (the )?)?(\w+ )?(few )?(days?|weeks?|monday|tuesday|wednesday|thursday|friday|eow|eod|week|month|sprint|tomorrow( morning)?|\d+ (hours|days|weeks))|next few days|end of (the )?week|tomorrow( morning)?|asap"#

func matches(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
}

func nextSteps(_ notes: String) -> String {
    guard let start = notes.range(of: "NEXT STEPS:") else { return "" }
    let rest = notes[start.upperBound...]
    let end = rest.range(of: "NEXT MEETING FOCUS:")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}

func complete(system: String, user: String, budget: ReviewBudget) throws -> (String, Int) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/chat")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 1200
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "model": model, "stream": false, "think": false, "keep_alive": "1m",
        "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        "options": ["temperature": 0.3, "num_ctx": budget.numCtx, "num_predict": budget.numPredict],
    ] as [String: Any])
    let done = DispatchSemaphore(value: 0)
    var result: Result<(String, Int), Error> = .failure(URLError(.unknown))
    URLSession.shared.dataTask(with: request) { data, _, error in
        defer { done.signal() }
        if let error { result = .failure(error); return }
        let json = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
        let content = (json?["message"] as? [String: Any])?["content"] as? String ?? ""
        result = .success((content, json?["prompt_eval_count"] as? Int ?? 0))
    }.resume()
    done.wait()
    return try result.get()
}

// Skip, don't fail, when no local engine is running.
if env["NOTES_RESCORE"] != "1", (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/api/tags")!)) == nil {
    print("notes bench: skipped (no Ollama on 127.0.0.1:\(port)). Set OLLAMA_PORT to use another local engine.")
    exit(0)
}

let lowerTranscript = transcript.lowercased()

/// A timeframe counts as said when the meeting contains it, with or without
/// the leading "by"/"within" the model adds ("by tomorrow morning").
func inventedDeadlines(_ notes: String) -> [String] {
    matches(deadlinePattern, in: nextSteps(notes)).filter { phrase in
        let bare = phrase.lowercased().replacingOccurrences(
            of: #"^(by|before|within|until|in) (the )?"#, with: "", options: .regularExpression)
        return !lowerTranscript.contains(phrase.lowercased()) && !lowerTranscript.contains(bare)
    }
}
var records: [[String: Any]] = []
print("notes bench · \(model) · transcript \(transcript.count) chars\n")
for mode in modes {
    let budget: ReviewBudget = mode == "roomy" ? .roomy : .standard
    let ctx = mode == "before" ? PreCallContext() : context
    let (system, user) = PromptBuilder.buildPostCallReviewPrompt(
        nudges: [], transcript: transcript, context: ctx, durationMinutes: 50,
        languageName: "English", budget: budget)
    let started = Date()
    // NOTES_RESCORE=1 re-scores the last saved notes without calling a model.
    let saved = dir.appendingPathComponent(".out/\(mode).txt")
    let (notes, promptTokens) = env["NOTES_RESCORE"] == "1"
        ? ((try? String(contentsOf: saved, encoding: .utf8)) ?? "", 0)
        : try complete(system: system, user: user, budget: budget)
    let caught = facts.filter { !matches($0.pattern, in: notes).isEmpty }.map(\.id)
    let invented = inventedDeadlines(notes)
    try notes.write(to: dir.appendingPathComponent(".out/\(mode).txt"), atomically: true, encoding: .utf8)
    let seconds = Int(Date().timeIntervalSince(started))
    print("\(mode.padding(toLength: 9, withPad: " ", startingAt: 0)) facts \(caught.count)/\(facts.count) · invented deadlines \(invented.count) · \(promptTokens) prompt tokens · \(seconds)s")
    for fact in facts where !caught.contains(fact.id) { print("          missed: \(fact.id)") }
    for phrase in invented { print("          invented: \"\(phrase)\"") }
    records.append(["mode": mode, "facts": caught.count, "of": facts.count,
                    "invented_deadlines": invented.count, "prompt_tokens": promptTokens])
}

let record: [String: Any] = [
    "date": ISO8601DateFormatter().string(from: Date()), "model": model,
    "commit": env["NOTES_COMMIT"] ?? "", "runs": records,
    "rescored": env["NOTES_RESCORE"] == "1",
]
let line = String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)! + "\n"
let history = dir.appendingPathComponent("history.jsonl")
if let handle = try? FileHandle(forWritingTo: history) {
    handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try handle.close()
} else {
    try line.write(to: history, atomically: true, encoding: .utf8)
}
print("\nappended to bench/notes/history.jsonl · notes in bench/notes/.out/")
