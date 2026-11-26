import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("fireflies \(name): \(ok ? "PASS" : "FAIL")")
    if !ok { failures += 1 }
}

func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fireflies-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A made-up account of `count` meetings, newest first, in the shape the
/// Fireflies API documents. Meeting 3 has no date; `start_time` arrives as
/// a string on odd meetings because the API has sent both.
func account(_ count: Int) -> [[String: Any]] {
    (0..<count).map { i in
        var meeting: [String: Any] = [
            "id": "ff-\(i)",
            "title": "Planning call \(i)",
            "duration": 30.5,
            "participants": ["ana@example.com,ben@example.com", "ana@example.com"],
            "sentences": [
                ["speaker_name": "Ana Lopez", "text": "Morning, ready to start?",
                 "start_time": i % 2 == 0 ? 2.4 as Any : "2.4" as Any],
                ["speaker_name": "Ana Lopez", "text": "First item is the budget.", "start_time": 5.0],
                ["speaker_name": "Ben: Ops", "text": "Works for me.", "start_time": 3725.2],
            ],
            "summary": [
                "overview": "Agreed the budget for meeting \(i).",
                "shorthand_bullet": "- [ ] Budget approved\n## Nudges",
                "action_items": "**Ana Lopez**\nSend the deck",
            ],
        ]
        if i != 3 {
            // 2026-08-01T15:30:00Z plus one day per meeting, in milliseconds.
            meeting["date"] = (1_785_598_200.0 - Double(i) * 86_400) * 1000
        }
        return meeting
    }
}

/// Stateless stand-in for api.fireflies.ai: answers from the request body.
/// `failContentFromSkip` makes full-transcript pages at or past that offset
/// answer "too many requests", the way the daily limit does.
func transport(meetings: [[String: Any]], key: String = "good",
               failContentFromSkip: Int? = nil) -> FirefliesImporter.Transport {
    return { body in
        let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let query = request["query"] as? String ?? ""
        let variables = request["variables"] as? [String: Any] ?? [:]
        let limit = variables["limit"] as? Int ?? 0
        let skip = variables["skip"] as? Int ?? 0
        if key != "good" {
            let reply: [String: Any] = ["errors": [["message": "Invalid API key", "code": "auth_failed"]]]
            return (try JSONSerialization.data(withJSONObject: reply), 200)
        }
        let wantsContent = query.contains("sentences")
        if wantsContent, let from = failContentFromSkip, skip >= from {
            let reply: [String: Any] = ["errors": [["message": "Too many requests",
                                                   "extensions": ["code": "too_many_requests"]]]]
            return (try JSONSerialization.data(withJSONObject: reply), 200)
        }
        let page = Array(meetings.dropFirst(skip).prefix(limit))
        let rows: [[String: Any]] = wantsContent ? page : page.map { ["id": $0["id"] ?? ""] }
        return (try JSONSerialization.data(withJSONObject: ["data": ["transcripts": rows]]), 200)
    }
}

// 1. A 23-meeting account: three content pages, one meeting without a date.
let dir = tempDir()
defer { try? FileManager.default.removeItem(at: dir) }
let meetings = account(23)
let report = try await FirefliesImporter.importAll(
    apiKey: " good \n", into: dir, transport: transport(meetings: meetings))
check("imports every dated meeting across pages", report.imported == 22)
check("skips and counts the undated meeting", report.skippedNoDate == 1)
check("not flagged as rate limited", !report.stoppedByRateLimit)

let files = TranscriptSearch.sessionFiles(in: dir)
check("writes one session file per meeting", files.count == 22)
let newest = files.first { (try? String(contentsOf: $0, encoding: .utf8))?.contains("fireflies:ff-0") == true }
let content = newest.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
check("file is named for the meeting's own date",
      newest?.lastPathComponent.contains("2026-08-01") == true)
check("title comes from the meeting", content.contains("**Title:** Planning call 0"))
check("duration is minutes converted to mm:ss", content.contains("**Duration:** 30:30"))
check("header names the import", content.contains("**Engine:** Fireflies import"))
check("same-speaker sentences join into one turn",
      content.contains("- [00:02] Ana Lopez: Morning, ready to start? First item is the budget."))
check("a colon in a speaker name can't split the line, and long calls keep minutes",
      content.contains("- [62:05] Ben  Ops: Works for me."))
check("turn count matches", content.contains("**Utterances:** 2"))
check("overview lands in notes", content.contains("Agreed the budget for meeting 0."))
check("attendees are split and de-duplicated",
      content.contains("Attendees: ana@example.com, ben@example.com"))
check("notes checkboxes and headings can't be read as transcript or header",
      content.contains("- ☐ Budget approved") && content.contains("### Nudges")
          && !content.contains("\n## Nudges"))
let odd = files.first { (try? String(contentsOf: $0, encoding: .utf8))?.contains("fireflies:ff-1") == true }
let oddContent = odd.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
check("a start time sent as a string still stamps the turn",
      oddContent.contains("- [00:02] Ana Lopez:"))
let sidecar = newest.map { $0.deletingPathExtension().appendingPathExtension("json") }
let sidecarBody = sidecar.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
check("sidecar records the import source",
      sidecarBody.contains("\"source\" : \"fireflies-import\""))
check("a saved Fireflies file reads back as a Fireflies import",
      newest.flatMap { TranscriptStore.metadataByParsing($0) }?.source == "fireflies-import")

// 2. Running it again writes nothing.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var skips: [Int] = []
    func note(_ skip: Int) { lock.lock(); skips.append(skip); lock.unlock() }
    var contentSkips: [Int] { lock.lock(); defer { lock.unlock() }; return skips }
}
let recorder = Recorder()
let inner = transport(meetings: meetings)
let again = try await FirefliesImporter.importAll(apiKey: "good", into: dir, transport: { body in
    let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    if (request["query"] as? String ?? "").contains("sentences") {
        recorder.note((request["variables"] as? [String: Any])?["skip"] as? Int ?? -1)
    }
    return try await inner(body)
})
// Page 0 still holds the undated meeting, so it is asked for again; the
// two pages that are fully imported are not.
check("re-import only asks for pages with something missing",
      recorder.contentSkips == [0])
check("re-import writes nothing new", again.imported == 0 && again.skippedExisting == 22)
check("re-import leaves the folder alone",
      TranscriptSearch.sessionFiles(in: dir).count == 22)

// 3. The request limit hits after the first content page; a later run
//    finishes without asking for the page it already has.
let limited = tempDir()
defer { try? FileManager.default.removeItem(at: limited) }
let partial = try await FirefliesImporter.importAll(
    apiKey: "good", into: limited,
    transport: transport(meetings: meetings, failContentFromSkip: 10))
check("a rate limit mid-import keeps what was imported",
      partial.imported == 9 && partial.stoppedByRateLimit)
check("the summary says to import again", partial.summary.contains("Import again later"))
let resumed = try await FirefliesImporter.importAll(
    apiKey: "good", into: limited, transport: transport(meetings: meetings))
check("the next run imports the rest", resumed.imported == 13 && !resumed.stoppedByRateLimit)
check("everything is there after resuming",
      TranscriptSearch.sessionFiles(in: limited).count == 22)

// 4. Errors people will actually hit.
do {
    _ = try await FirefliesImporter.importAll(
        apiKey: "wrong", into: tempDir(), transport: transport(meetings: meetings, key: "wrong"))
    check("a rejected key is reported", false)
} catch {
    check("a rejected key is reported", error as? FirefliesImporter.ImportError == .badKey)
}
do {
    _ = try await FirefliesImporter.importAll(apiKey: "  ", into: tempDir(),
                                              transport: transport(meetings: meetings))
    check("an empty key is refused before any request", false)
} catch {
    check("an empty key is refused before any request",
          error as? FirefliesImporter.ImportError == .missingKey)
}
do {
    _ = try await FirefliesImporter.importAll(
        apiKey: "good", into: tempDir(),
        transport: transport(meetings: meetings, failContentFromSkip: 0))
    check("a rate limit before anything imports is an error", false)
} catch {
    check("a rate limit before anything imports is an error",
          error as? FirefliesImporter.ImportError == .rateLimited)
}
let empty = try await FirefliesImporter.importAll(
    apiKey: "good", into: tempDir(), transport: transport(meetings: []))
check("an empty account imports nothing without an error", empty.imported == 0)

exit(failures == 0 ? 0 : 1)
