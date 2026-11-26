import Foundation

/// Import of Fireflies.ai meeting history into MeetMouse sessions.
///
/// Fireflies has no one-file export of every meeting, so this reads the
/// account through Fireflies' own GraphQL API with the user's API key
/// (Fireflies → Integrations → Fireflies API). The request goes from this
/// Mac straight to api.fireflies.ai and only when the user clicks Import;
/// the key is used for that run and never written anywhere.
///
/// Imported meetings are ordinary session files (same writer as the Granola
/// import) with a `fireflies:<id>` dedupe marker, so a second run only
/// fetches and writes what is missing.
enum FirefliesImporter {
    static let endpoint = URL(string: "https://api.fireflies.ai/graphql")!
    /// Meetings per request when listing ids (Fireflies' documented maximum).
    static let idPageSize = 50
    /// Meetings per request when fetching full transcripts. Small on
    /// purpose: a page carries every sentence of every meeting in it.
    static let contentPageSize = 10

    struct Report: Sendable, Equatable {
        var imported = 0
        var skippedExisting = 0
        var skippedNoDate = 0
        /// Fireflies stopped answering (daily request limit) before the
        /// whole account was read. Running the import again continues.
        var stoppedByRateLimit = false

        var summary: String {
            var parts = ["Imported \(imported) meeting\(imported == 1 ? "" : "s")"]
            if skippedExisting > 0 { parts.append("\(skippedExisting) already imported") }
            if skippedNoDate > 0 { parts.append("\(skippedNoDate) skipped (no date)") }
            var text = parts.joined(separator: " · ")
            if stoppedByRateLimit {
                text += ". Fireflies' request limit was reached before the rest could be read. Import again later to continue; meetings already imported are skipped."
            }
            return text
        }
    }

    enum ImportError: LocalizedError, Equatable {
        case missingKey
        case badKey
        case rateLimited
        case network(String)
        case unexpectedResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                return "Paste your Fireflies API key first."
            case .badKey:
                return "Fireflies didn't accept that API key. Copy it again from Fireflies → Integrations → Fireflies API."
            case .rateLimited:
                return "Fireflies' request limit for this API key is used up for now. Try the import again later."
            case .network(let detail):
                return "Couldn't reach Fireflies: \(detail)"
            case .unexpectedResponse(let detail):
                return "Fireflies sent a reply MeetMouse couldn't read: \(detail)"
            }
        }
    }

    /// One meeting as the API returns it, read leniently: Fireflies has
    /// changed field types before (numbers arriving as strings), and a
    /// field that fails to parse should cost that field, not the meeting.
    struct Meeting: Equatable {
        struct Sentence: Equatable {
            var speaker: String
            var text: String
            var start: TimeInterval?
        }
        var id: String
        var title: String
        var date: Date?
        var duration: TimeInterval?
        var participants: [String]
        var sentences: [Sentence]
        var overview: String
        var bullets: String
        var actionItems: String
    }

    /// POSTs a JSON body, returns the reply body and HTTP status. Injected
    /// so the paging and error handling can be tested without a network.
    typealias Transport = @Sendable (Data) async throws -> (Data, Int)

    // MARK: - Import

    static func importAll(apiKey: String,
                          into dir: URL = AppSupport.sessionsDir,
                          transport: Transport? = nil,
                          rateLimitWait: TimeInterval = 20,
                          rateLimitRetries: Int = 4,
                          progress: (@Sendable (String) -> Void)? = nil) async throws -> Report {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ImportError.missingKey }
        let transport = transport ?? liveTransport(apiKey: key)
        // Fireflies limits requests per minute as well as per day. A short
        // wait clears the per-minute limit; if it doesn't, stop and let a
        // later run continue.
        let send: Transport = { body in
            var attempt = 0
            while true {
                let reply = try await transport(body)
                guard isRateLimited(reply), attempt < rateLimitRetries else { return reply }
                attempt += 1
                progress?("Fireflies asked for a pause. Continuing in a few seconds…")
                try await Task.sleep(nanoseconds: UInt64(max(0, rateLimitWait) * 1_000_000_000))
            }
        }

        // Pass 1: ids only. Cheap, and it tells us which pages still hold
        // something new, so a re-run doesn't spend the request quota
        // re-downloading meetings that are already here.
        progress?("Reading your Fireflies meeting list…")
        var ids: [String] = []
        while true {
            let page = try await query(
                "query($limit:Int,$skip:Int){transcripts(limit:$limit,skip:$skip){id}}",
                variables: ["limit": idPageSize, "skip": ids.count], send: send)
            ids.append(contentsOf: page.compactMap { $0["id"] as? String })
            if page.count < idPageSize { break }
        }

        var existing = Set(GranolaImporter.existingImportMarkers(in: dir).keys)
        var report = Report()
        report.skippedExisting = ids.filter { existing.contains(marker(for: $0)) }.count

        // Pass 2: full meetings, only for pages that hold a missing id.
        let missing = ids.filter { !existing.contains(marker(for: $0)) }.count
        var offset = 0
        while offset < ids.count {
            let pageIDs = ids[offset..<min(offset + contentPageSize, ids.count)]
            defer { offset += contentPageSize }
            guard pageIDs.contains(where: { !existing.contains(marker(for: $0)) }) else { continue }
            progress?("Importing from Fireflies… \(report.imported) of \(missing)")
            let page: [[String: Any]]
            do {
                page = try await query(contentQuery,
                                       variables: ["limit": contentPageSize, "skip": offset],
                                       send: send)
            } catch ImportError.rateLimited where report.imported > 0 {
                report.stoppedByRateLimit = true
                break
            }
            let meetings = page.compactMap(meeting(from:))
            let pageReport = write(meetings, into: dir, existing: &existing)
            report.imported += pageReport.imported
            report.skippedNoDate += pageReport.skippedNoDate
        }
        return report
    }

    /// The fields here are the ones Fireflies documents on Transcript,
    /// Sentence and Summary. Kept to what the session file uses.
    static let contentQuery = """
    query($limit:Int,$skip:Int){transcripts(limit:$limit,skip:$skip){\
    id title date dateString duration participants \
    sentences{speaker_name text start_time} \
    summary{overview shorthand_bullet action_items}}}
    """

    static func marker(for id: String) -> String { "fireflies:\(id)" }

    /// Writes the meetings that aren't in the folder yet. `existing` is
    /// updated as files are written, so a meeting that shows up on two
    /// pages (the list shifted while paging) is still written once.
    @discardableResult
    static func write(_ meetings: [Meeting], into dir: URL,
                      existing: inout Set<String>) -> Report {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report = Report()
        for meeting in meetings {
            let marker = marker(for: meeting.id)
            if existing.contains(marker) {
                report.skippedExisting += 1
                continue
            }
            let transcript = transcriptLines(meeting.sentences)
            let notes = notesBody(meeting)
            guard !meeting.title.isEmpty || !notes.isEmpty || !transcript.isEmpty else { continue }
            guard let date = meeting.date else {
                // A wrong date in a date-keyed archive is worse than absence.
                report.skippedNoDate += 1
                continue
            }
            GranolaImporter.write(marker: marker, title: meeting.title, date: date,
                                  duration: meeting.duration, notes: notes,
                                  transcript: transcript, attendees: meeting.participants,
                                  into: dir, engine: "Fireflies import",
                                  source: "fireflies-import")
            existing.insert(marker)
            report.imported += 1
        }
        return report
    }

    // MARK: - Shaping

    /// Fireflies returns one row per sentence. The app reads speaker turns,
    /// so consecutive sentences by the same speaker become one line, stamped
    /// with the time the turn started.
    static func transcriptLines(_ sentences: [Meeting.Sentence]) -> [String] {
        var turns: [(speaker: String, start: TimeInterval?, text: String)] = []
        for sentence in sentences {
            let text = sentence.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let speaker = speakerLabel(sentence.speaker)
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1].text += " " + text
            } else {
                turns.append((speaker, sentence.start, text))
            }
        }
        return turns.map { turn in
            let stamp: String
            if let start = turn.start, start >= 0 {
                let total = Int(start)
                stamp = String(format: "%02d:%02d", total / 60, total % 60)
            } else {
                stamp = "--:--"
            }
            return "- [\(stamp)] \(turn.speaker): \(turn.text)"
        }
    }

    /// A speaker label must not contain ":" or a line break, or the session
    /// parsers would split the line in the wrong place.
    private static func speakerLabel(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Speaker" : cleaned
    }

    static func notesBody(_ meeting: Meeting) -> String {
        var parts: [String] = []
        if !meeting.participants.isEmpty {
            parts.append("Attendees: \(meeting.participants.joined(separator: ", "))")
        }
        if !meeting.overview.isEmpty { parts.append(meeting.overview) }
        if !meeting.bullets.isEmpty { parts.append("### Notes\n\(meeting.bullets)") }
        if !meeting.actionItems.isEmpty { parts.append("### Action items\n\(meeting.actionItems)") }
        return parts.joined(separator: "\n\n")
    }

    /// One API transcript object → Meeting. Nil only without an id.
    static func meeting(from object: [String: Any]) -> Meeting? {
        guard let id = string(object["id"]), !id.isEmpty else { return nil }
        let summary = object["summary"] as? [String: Any] ?? [:]
        let sentences = (object["sentences"] as? [[String: Any]] ?? []).map {
            Meeting.Sentence(speaker: string($0["speaker_name"]) ?? "",
                             text: string($0["text"]) ?? "",
                             start: number($0["start_time"]))
        }
        // `duration` is in minutes.
        let minutes = number(object["duration"])
        return Meeting(
            id: id,
            title: (string(object["title"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            date: date(epochMillis: object["date"], iso: object["dateString"]),
            duration: minutes.flatMap { $0 > 0 ? $0 * 60 : nil },
            participants: participants(object["participants"]),
            sentences: sentences,
            overview: text(summary["overview"]),
            bullets: text(summary["shorthand_bullet"]),
            actionItems: text(summary["action_items"]))
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Summary fields are documented as strings, but tolerate a list.
    private static func text(_ value: Any?) -> String {
        if let list = value as? [Any] {
            return list.compactMap { string($0) }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (string(value) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `participants` is a list of email addresses; Fireflies sometimes
    /// packs several into one comma-separated entry and repeats them.
    private static func participants(_ value: Any?) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in (value as? [Any] ?? []).compactMap({ string($0) }) {
            for piece in entry.split(separator: ",") {
                let name = piece.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, seen.insert(name.lowercased()).inserted { out.append(name) }
            }
        }
        return out
    }

    private static func date(epochMillis: Any?, iso: Any?) -> Date? {
        if let millis = number(epochMillis), millis > 0 {
            // Milliseconds since 1970; a value this small would be seconds.
            return Date(timeIntervalSince1970: millis > 100_000_000_000 ? millis / 1000 : millis)
        }
        guard let text = string(iso), !text.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: - Transport

    /// Runs one GraphQL query and returns the `transcripts` list.
    static func query(_ query: String, variables: [String: Any],
                      send: Transport) async throws -> [[String: Any]] {
        let payload: [String: Any] = ["query": query, "variables": variables]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let reply: (Data, Int)
        do {
            reply = try await send(body)
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.network(error.localizedDescription)
        }
        let (data, status) = reply
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // GraphQL reports failures in `errors`, often with HTTP 200.
        let errors = json?["errors"] as? [[String: Any]] ?? []
        let codes = errorCodes(json)
        if isRateLimited(reply) { throw ImportError.rateLimited }
        if status == 401 || status == 403
            || codes.contains(where: { ["auth_failed", "unauthenticated", "forbidden", "invalid_api_key"].contains($0) }) {
            throw ImportError.badKey
        }
        if let first = errors.first {
            let message = (first["message"] as? String) ?? "unknown error"
            throw ImportError.unexpectedResponse(String(message.prefix(200)))
        }
        guard (200..<300).contains(status) else {
            throw ImportError.unexpectedResponse("HTTP \(status)")
        }
        guard let dataObject = json?["data"] as? [String: Any],
              let list = dataObject["transcripts"] as? [[String: Any]] else {
            // `transcripts: null` is how an empty account can come back.
            if let dataObject = json?["data"] as? [String: Any], dataObject["transcripts"] is NSNull {
                return []
            }
            throw ImportError.unexpectedResponse("no meeting list in the reply")
        }
        return list
    }

    private static func errorCodes(_ json: [String: Any]?) -> [String] {
        let errors = json?["errors"] as? [[String: Any]] ?? []
        return errors.flatMap { error -> [String] in
            let extensions = error["extensions"] as? [String: Any]
            return [error["code"] as? String, extensions?["code"] as? String].compactMap { $0 }
        }.map { $0.lowercased() }
    }

    static func isRateLimited(_ reply: (Data, Int)) -> Bool {
        if reply.1 == 429 { return true }
        let json = (try? JSONSerialization.jsonObject(with: reply.0)) as? [String: Any]
        return errorCodes(json).contains("too_many_requests")
    }

    private static func liveTransport(apiKey: String) -> Transport {
        { body in
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            request.timeoutInterval = 60
            // Ephemeral: no cookies or cache left behind by the import.
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}
