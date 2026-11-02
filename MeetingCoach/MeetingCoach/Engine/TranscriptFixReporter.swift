import Foundation

/// Opt-in transcript fixes (decisions.md 2026-11-02 "transcript fixes").
///
/// A THIRD toggle, separate from usage counts and coaching feedback, OFF by
/// default (Settings → General → "Help improve transcripts"). When on, each
/// "Fix a misheard term" the user makes is queued as a short heard→corrected
/// pair (at most 5 words / 60 characters a side) with the engine id and the
/// meeting language. Never audio, never transcript lines, never notes.
/// A pair is dropped whole when either side looks personal (email, URL,
/// domain, 4+ digits, key/token), mentions anyone in the meeting, or the
/// corrected side reads like a person's name (Title Case words only) unless
/// the user's vocabulary lists it as a bare glossary term. The queue is
/// visible in Settings (delete one or all) and sent at most once a week to
/// meetmouse.com/api/transcript-fixes. The weekly improve workflow bundles
/// pairs taught on 3+ Macs into Resources/common_corrections.json.
///
/// Plain types only so tests/transcripts compiles this file standalone.
struct TranscriptFixLedger {
    static let endpoint = URL(string: "https://meetmouse.com/api/transcript-fixes")!
    static let maxQueued = 200
    static let maxPerReport = 200
    /// Unsent fixes older than this are dropped (the server rejects > 60 days).
    static let keepDays = 45
    static let minInterval: TimeInterval = 7 * 86_400

    struct Fix: Codable, Equatable, Identifiable {
        var fixId: String
        var day: String
        var heard: String
        var corrected: String
        var engine: String
        var language: String
        var id: String { fixId }
    }

    struct Report: Codable, Equatable {
        var installId: String
        var appVersion: String
        var fixes: [Fix]
    }

    enum Key {
        static let optedIn = "shareTranscriptFixes"
        static let installId = "transcriptFixes.installId"
        static let queue = "transcriptFixes.queue"
        static let lastSentAt = "transcriptFixes.lastSentAt"
    }

    let defaults: UserDefaults
    var now: () -> Date = Date.init
    var calendar: Calendar = .current

    static var isAllowedInThisBuild: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["MEETMOUSE_USAGE_DEBUG"] == "1"
        #else
        return true
        #endif
    }

    var isOptedIn: Bool { defaults.bool(forKey: Key.optedIn) && installId != nil }
    var installId: String? { defaults.string(forKey: Key.installId) }

    /// Returns the install id removed on opt-out (so the caller can ask the
    /// server to delete its rows), nil otherwise.
    @discardableResult
    func setOptedIn(_ on: Bool) -> String? {
        defaults.set(on, forKey: Key.optedIn)
        if on {
            if installId == nil { defaults.set(UUID().uuidString, forKey: Key.installId) }
            return nil
        }
        let removed = installId
        defaults.removeObject(forKey: Key.installId)
        defaults.removeObject(forKey: Key.queue)
        defaults.removeObject(forKey: Key.lastSentAt)
        return removed
    }

    var pending: [Fix] {
        guard let data = defaults.data(forKey: Key.queue),
              let fixes = try? JSONDecoder().decode([Fix].self, from: data) else { return [] }
        return fixes
    }

    func delete(_ fixId: String) { save(pending.filter { $0.fixId != fixId }) }

    /// "Delete all" in Settings: drops the unsent queue, stays opted in.
    func deletePending() { defaults.removeObject(forKey: Key.queue) }

    private func save(_ fixes: [Fix]) {
        if fixes.isEmpty {
            defaults.removeObject(forKey: Key.queue)
        } else if let data = try? JSONEncoder().encode(fixes) {
            defaults.set(data, forKey: Key.queue)
        }
    }

    func dayString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Queues one fix. Returns false (and queues nothing) unless opted in and
    /// the pair passes every scrub rule.
    @discardableResult
    func record(heard: String, corrected: String, engine: String, language: String,
                knownNames: [String], glossary: Set<String>) -> Bool {
        guard isOptedIn,
              let pair = TranscriptFixScrub.scrubbed(heard: heard, corrected: corrected,
                                                     knownNames: knownNames, glossary: glossary)
        else { return false }
        let fix = Fix(fixId: UUID().uuidString, day: dayString(now()),
                      heard: pair.heard, corrected: pair.corrected,
                      engine: TranscriptFixScrub.engineId(engine),
                      language: TranscriptFixScrub.languageCode(language))
        let cutoff = dayString(now().addingTimeInterval(-Double(Self.keepDays) * 86_400))
        let kept = pending.filter {
            $0.day >= cutoff
                && !($0.heard.lowercased() == fix.heard.lowercased() && $0.corrected == fix.corrected)
        }
        save(Array((kept + [fix]).suffix(Self.maxQueued)))
        return true
    }

    /// The report to send now, or nil: at most once a week.
    func dueReport(appVersion: String) -> Report? {
        guard isOptedIn, let installId else { return nil }
        if let last = defaults.object(forKey: Key.lastSentAt) as? Date,
           now().timeIntervalSince(last) < Self.minInterval { return nil }
        let queued = pending
        guard !queued.isEmpty else { return nil }
        return Report(installId: installId, appVersion: appVersion,
                      fixes: Array(queued.prefix(Self.maxPerReport)))
    }

    /// Accepted (2xx) or permanently rejected (4xx except 429): forget those
    /// fixes so a bad one can't retry forever.
    func markSent(_ report: Report) {
        guard isOptedIn, installId == report.installId else { return }
        let sent = Set(report.fixes.map(\.fixId))
        save(pending.filter { !sent.contains($0.fixId) })
        defaults.set(now(), forKey: Key.lastSentAt)
    }
}

/// What may leave this Mac from a "Fix a misheard term" pair. The length and
/// personal-data rules are mirrored by the Worker (web-share/src/transcriptFixes.js)
/// and the merge script (scripts/improve/merge_transcript_fixes.py); the shared
/// fixture tests/transcripts/scrub_cases.json holds all three to the same cases.
/// The names rules are app-only: only the app knows who was in the meeting.
enum TranscriptFixScrub {
    static let maxWords = 5
    static let maxChars = 60

    static func scrubbed(heard: String, corrected: String, knownNames: [String] = [],
                         glossary: Set<String> = []) -> (heard: String, corrected: String)? {
        let heard = collapse(heard)
        let corrected = collapse(corrected)
        guard heard != corrected, isShareable(heard), isShareable(corrected) else { return nil }
        let names = nameTokens(knownNames)
        guard !mentionsName(heard, names), !mentionsName(corrected, names) else { return nil }
        if isNameLike(corrected), !glossary.contains(corrected.lowercased()) { return nil }
        return (heard, corrected)
    }

    static func isShareable(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxChars,
              text.rangeOfCharacter(from: .letters) != nil,
              text.split(separator: " ").count <= maxWords else { return false }
        return !looksPersonal(text)
    }

    static let personalPatterns: [NSRegularExpression] = [
        #"[\x00-\x1f\x7f<>]"#,                               // control chars / markup
        #"[^\s@]+@[^\s@]+\.[^\s@]+"#,                        // email
        #"(?i)\b(https?://|www\.)"#,                         // URL
        #"(?i)\b[a-z0-9-]+\.(com|net|org|io|app|ai|co|dev|me|us|uk|de)\b"#, // bare domain
        #"\d[\d\s.,-]{2,}\d"#,                               // 4+ digits, even with separators
        #"\d{4,}"#,                                          // 4+ digits
        #"(?i)\b(sk|pk|rk|ghp|gho|xox[abp]|akia)[-_][A-Za-z0-9]"#,  // well-known key prefixes
        #"[A-Za-z0-9_\-]{24,}"#,                             // long token
        #"\b(?=[A-Za-z0-9]*\d)(?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]{12,}\b"#, // mixed letters+digits ≥12
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func looksPersonal(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return personalPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "Sarah", "John Smith", "O'Neil" — every word Title Case with no other
    /// capitals. Product terms keep a tell (TidyCal, MRR, iPhone, Q3 plan) and
    /// pass; plain Title Case words are treated as someone's name and dropped.
    static func isNameLike(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return false }
        return words.allSatisfy {
            String($0).range(of: #"^[A-Z][a-z]+(['’-][A-Za-z][a-z]*)*$"#,
                             options: .regularExpression) != nil
        }
    }

    /// Speaker labels the app generates on its own — not anybody's name.
    private static let genericLabels: Set<String> = [
        "you", "them", "me", "meeting", "speaker", "remote", "guest", "unknown",
        "person", "other", "host", "mic", "system",
    ]

    /// Lowercased words (3+ letters) of every participant and speaker name.
    static func nameTokens(_ names: [String]) -> Set<String> {
        var out = Set<String>()
        for name in names {
            for word in name.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            where word.count >= 3 && !genericLabels.contains(word) {
                out.insert(word)
            }
        }
        return out
    }

    static func mentionsName(_ text: String, _ tokens: Set<String>) -> Bool {
        guard !tokens.isEmpty else { return false }
        return text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .contains { tokens.contains($0) }
    }

    /// Bare lines in the user's vocabulary ("Figma", no "=") are glossary
    /// terms the user taught on purpose — lowercased for lookup.
    static func glossaryTerms(fromVocabulary text: String) -> Set<String> {
        Set(text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = collapse(line)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.contains("=") else { return nil }
            return trimmed.lowercased()
        })
    }

    static let engines: Set<String> = ["parakeetV2", "parakeetV3", "sfSpeech"]

    /// A TranscriptionEngine raw value, or "" — never a free-form label.
    static func engineId(_ raw: String) -> String { engines.contains(raw) ? raw : "" }

    /// "en", "pt-BR", "auto" — anything else becomes "".
    static func languageCode(_ raw: String) -> String {
        raw.range(of: #"^([a-z]{2,3}(-[A-Za-z]{2,4})?|auto)$"#, options: .regularExpression) != nil ? raw : ""
    }
}

/// Network side. Sends at launch and after meetings; deletes on opt-out.
enum TranscriptFixReporter {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func record(heard: String, corrected: String, engine: String, language: String,
                       knownNames: [String], glossary: Set<String>) {
        guard TranscriptFixLedger.isAllowedInThisBuild else { return }
        TranscriptFixLedger(defaults: .standard).record(
            heard: heard, corrected: corrected, engine: engine, language: language,
            knownNames: knownNames, glossary: glossary)
    }

    static func sendIfDue() async {
        guard TranscriptFixLedger.isAllowedInThisBuild else { return }
        let ledger = TranscriptFixLedger(defaults: .standard)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard let report = ledger.dueReport(appVersion: version),
              let body = try? JSONEncoder().encode(report) else { return }
        var request = URLRequest(url: TranscriptFixLedger.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let result = try? await session.data(for: request),
              let status = (result.1 as? HTTPURLResponse)?.statusCode else { return }
        if (200..<300).contains(status) || ((400..<500).contains(status) && status != 429) {
            TranscriptFixLedger(defaults: .standard).markSent(report)
        }
    }

    /// Opt-out: ask the server to delete what this install sent. Best effort;
    /// anything left is purged after 180 days regardless.
    static func deleteRemote(installId: String) async {
        guard TranscriptFixLedger.isAllowedInThisBuild,
              let url = URL(string: TranscriptFixLedger.endpoint.absoluteString + "/" + installId) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await session.data(for: request)
    }
}
