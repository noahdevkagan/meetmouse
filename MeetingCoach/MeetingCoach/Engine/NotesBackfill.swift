import Foundation

/// AI notes for meetings whose automatic notes did not get written.
///
/// The notes that follow Stop run inside the live session. Two things used
/// to leave a meeting without them: the AI call failed once (a busy CLI, a
/// usage limit, no network for a moment) and the basic recap stayed for
/// good, or the next meeting started while the notes were still being
/// written and they were dropped. Either way the meeting only got AI notes
/// when someone opened it and pressed Regenerate.
///
/// Such a meeting is queued here instead and its notes are written from the
/// saved file, the same way Regenerate does it: shortly after the failure,
/// then when a later meeting ends, then at the next launch.
@MainActor
enum NotesBackfill {
    static let didWrite = Notification.Name("MeetMouse.notesBackfillDidWrite")
    static let defaultsKey = "pendingAINotes"
    static let maxAttempts = 6
    /// After the two quick retries, attempts for one meeting are at least
    /// this far apart: a usage limit does not clear in a minute.
    static let laterSpacing: TimeInterval = 15 * 60
    static let quickRetries: [TimeInterval] = [45, 300]

    private static var running = false

    struct Entry: Equatable {
        var attempts = 0
        var lastAttempt: Date?
    }

    // MARK: - Queue

    static func entries(defaults: UserDefaults = .standard) -> [String: Entry] {
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: [String: Double]] ?? [:]
        return stored.mapValues { value in
            Entry(attempts: Int(value["attempts"] ?? 0),
                  lastAttempt: value["last"].map { Date(timeIntervalSince1970: $0) })
        }
    }

    private static func store(_ entries: [String: Entry], defaults: UserDefaults) {
        defaults.set(entries.mapValues { entry -> [String: Double] in
            var value = ["attempts": Double(entry.attempts)]
            if let last = entry.lastAttempt { value["last"] = last.timeIntervalSince1970 }
            return value
        }, forKey: defaultsKey)
    }

    static func enqueue(_ path: String, defaults: UserDefaults = .standard) {
        var all = entries(defaults: defaults)
        guard all[path] == nil else { return }
        all[path] = Entry()
        store(all, defaults: defaults)
        mclog("[Notes] Queued for automatic retry: \(URL(fileURLWithPath: path).lastPathComponent)")
    }

    /// The meeting has its notes (or never will): stop retrying.
    static func resolve(_ path: String, defaults: UserDefaults = .standard) {
        var all = entries(defaults: defaults)
        guard all.removeValue(forKey: path) != nil else { return }
        store(all, defaults: defaults)
    }

    /// Queued meetings that may be tried now, oldest file first. The first
    /// attempts follow the quick retry schedule; later ones are spaced out.
    static func due(now: Date = Date(), defaults: UserDefaults = .standard) -> [String] {
        entries(defaults: defaults).filter { _, entry in
            guard let last = entry.lastAttempt else { return true }
            let wait = entry.attempts <= quickRetries.count
                ? quickRetries[max(0, entry.attempts - 1)] - 5 : laterSpacing
            return now.timeIntervalSince(last) >= wait
        }.keys.sorted()
    }

    // MARK: - What a saved meeting gives the notes prompt

    struct Source: Equatable {
        var transcript: String
        var durationMinutes: Int
        var languageCode: String?
        var lineTexts: [String]
    }

    /// Nil when the file has no transcript to write notes from.
    static func source(in content: String) -> Source? {
        var lines: [String] = []
        var texts: [String] = []
        var duration = 1
        var language: String?
        var section = ""
        for raw in content.components(separatedBy: "\n") {
            if raw.hasPrefix("## ") { section = raw; continue }
            if section.hasPrefix("## Transcript"),
               let parsed = TranscriptSearch.parseTranscriptLine(raw) {
                lines.append("\(parsed.speaker): \(parsed.text)")
                texts.append(parsed.text)
            } else if raw.hasPrefix("**Duration:**") {
                duration = minutes(raw.dropFirst("**Duration:**".count)
                    .trimmingCharacters(in: .whitespaces))
            } else if raw.hasPrefix("**Language:**") {
                language = raw.dropFirst("**Language:**".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !lines.isEmpty else { return nil }
        return Source(transcript: lines.joined(separator: "\n"), durationMinutes: duration,
                      languageCode: language, lineTexts: texts)
    }

    /// "32:10", "1:02:03" or "32 min" as whole minutes, at least 1.
    static func minutes(_ text: String) -> Int {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        let total: Int
        switch parts.count {
        case 3: total = parts[0] * 60 + parts[1]
        case 2: total = parts[0]
        default: total = Int(text.prefix(while: \.isNumber)) ?? 1
        }
        return max(1, total)
    }

    // MARK: - Run

    /// Write notes for every queued meeting that is due. `meetingInProgress`
    /// guards local models: one must not load beside a live call's
    /// transcription. `onWritten` lets the session that still shows the
    /// meeting take the new notes instead of its basic recap.
    static func run(settings: SettingsViewModel, ollamaManager: OllamaManager,
                    meetingInProgress: @MainActor () -> Bool,
                    onWritten: @MainActor (String, MeetingReview) -> Void = { _, _ in },
                    defaults: UserDefaults = .standard) async {
        guard !running, !settings.useMock else { return }
        running = true
        defer { running = false }
        for path in due(defaults: defaults) {
            if !settings.usesCloudAI && meetingInProgress() { break }
            let url = URL(fileURLWithPath: path)
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  !MeetingNotesFile.isEdited(content),
                  let source = source(in: content) else {
                // Deleted, hand-edited, or nothing to summarize.
                resolve(path, defaults: defaults)
                continue
            }
            guard await settings.prepareAI(ollamaManager: ollamaManager) else { break }

            var all = entries(defaults: defaults)
            var entry = all[path] ?? Entry()
            entry.attempts += 1
            entry.lastAttempt = Date()
            all[path] = entry
            store(all, defaults: defaults)

            let model = settings.effectiveModel
            let budget = ReviewBudget.forModel(model)
            let savedLanguage = source.languageCode.flatMap {
                MeetingLanguageSelection.resolvedPersistedCode($0)?.language
            }
            let (system, user) = PromptBuilder.buildPostCallReviewPrompt(
                nudges: [], transcript: source.transcript,
                context: PreCallContext.saved(in: content),
                durationMinutes: source.durationMinutes,
                languageName: settings.notesLanguage.notesLanguageName(
                    meetingLanguage: savedLanguage,
                    detected: savedLanguage == nil && settings.notesLanguage == .meeting
                        ? TranscriptLanguageDetector.tally(source.lineTexts).dominant : nil),
                budget: budget)
            do {
                // The session's own review call (and its test seam).
                let text = try await LiveSessionViewModel.completeReview(model, system, user)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIError.message("AI returned no notes.")
                }
                // The file may have changed while the model worked (speaker
                // names, a manual Regenerate): replace only the notes, and
                // never notes someone edited meanwhile.
                guard let latest = try? String(contentsOf: url, encoding: .utf8),
                      !MeetingNotesFile.isEdited(latest) else {
                    resolve(path, defaults: defaults)
                    continue
                }
                let review = MeetingReview.parse(llmText: text,
                                                 talkShare: MeetingNotesFile.talkShare(in: latest))
                try MeetingNotesFile.replacingReview(in: latest, with: review)
                    .write(to: url, atomically: true, encoding: .utf8)
                resolve(path, defaults: defaults)
                mclog("[Notes] Automatic retry wrote AI notes: \(url.lastPathComponent)")
                if let title = review.title {
                    TranscriptSearch.adoptGeneratedTitle(title, for: url)
                }
                onWritten(path, review)
                NotificationCenter.default.post(name: didWrite, object: url)
                // Team members share notes by default; TeamSpace listens.
                NotificationCenter.default.post(name: Notification.Name("MeetMouse.meetingNotesReady"),
                                                object: nil, userInfo: ["path": path])
            } catch {
                mclog("[Notes] Automatic retry \(entry.attempts)/\(maxAttempts) failed: \(url.lastPathComponent)")
                if entry.attempts >= maxAttempts { resolve(path, defaults: defaults) }
                // The provider is failing; the rest of the queue waits too.
                break
            }
        }
    }

    /// Notes that were finished for a meeting the session has moved on from
    /// (the next call started while they were being written): saved to its
    /// file directly. False when the file is gone or its notes were edited.
    static func save(_ summary: String, toPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let content = try? String(contentsOf: url, encoding: .utf8),
              !MeetingNotesFile.isEdited(content) else { return false }
        let review = MeetingReview.parse(llmText: summary,
                                         talkShare: MeetingNotesFile.talkShare(in: content))
        guard (try? MeetingNotesFile.replacingReview(in: content, with: review)
            .write(to: url, atomically: true, encoding: .utf8)) != nil else { return false }
        if let title = review.title { TranscriptSearch.adoptGeneratedTitle(title, for: url) }
        NotificationCenter.default.post(name: didWrite, object: url)
        NotificationCenter.default.post(name: Notification.Name("MeetMouse.meetingNotesReady"),
                                        object: nil, userInfo: ["path": path])
        return true
    }
}
