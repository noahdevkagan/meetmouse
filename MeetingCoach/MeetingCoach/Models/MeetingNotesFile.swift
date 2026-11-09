import Foundation

/// Reads and rewrites the notes part of saved meeting files: the "## Review"
/// section (always last in the file), the "Notes edited" header marker, and
/// open follow-ups gathered across meetings for the home screen. The markdown
/// file stays the single source of truth; nothing here keeps a second store.
enum MeetingNotesFile {
    static let didChange = Notification.Name("MeetMouse.meetingNotesDidChange")

    // MARK: - Review section

    /// The saved notes text, or nil when the meeting has none yet.
    static func reviewText(in content: String) -> String? {
        guard let range = content.range(of: "\n## Review") else { return nil }
        var rest = content[range.upperBound...]
        if let lineEnd = rest.firstIndex(of: "\n") { rest = rest[lineEnd...] } else { return nil }
        let text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Parsed notes, with the header's talk ratio so a rewrite keeps the
    /// "Talk split" line.
    static func review(in content: String) -> MeetingReview? {
        reviewText(in: content).map { MeetingReview.parseSavedMarkdown($0, talkShare: talkShare(in: content)) }
    }

    static func talkShare(in content: String) -> Double? {
        guard let line = headerLines(content).first(where: { $0.hasPrefix("**Talk ratio:**") }) else { return nil }
        let digits = line.dropFirst("**Talk ratio:**".count)
            .trimmingCharacters(in: .whitespaces).prefix(while: \.isNumber)
        return Int(digits).map { Double($0) / 100 }
    }

    /// Same rewrite every notes writer uses: drop the old section, append
    /// the new one.
    static func replacingReview(in content: String, with review: MeetingReview) -> String {
        var head = content
        if let range = head.range(of: "\n## Review") { head = String(head[..<range.lowerBound]) }
        head = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "\n\n## Review\n\n\(review.recapMarkdown)\n"
    }

    /// Optimistic write for delayed AI work. Check the file, not a view's
    /// cached review: another window or Home may have changed its notes.
    /// Call synchronously on the main actor with other in-app note writers.
    @MainActor
    static func saveRewrite(_ review: MeetingReview, to url: URL,
                            expectedContent: String) throws -> String? {
        let latest = try String(contentsOf: url, encoding: .utf8)
        guard latest == expectedContent else { return nil }
        let updated = replacingReview(in: latest, with: review)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: didChange, object: url)
        return updated
    }

    // MARK: - Edited marker

    /// Header line written once the user edits notes by hand. Regenerating
    /// all notes asks before replacing them while it's present.
    static let editedLabel = "**Notes edited:**"

    static func isEdited(_ content: String) -> Bool {
        headerLines(content).contains { $0.hasPrefix(editedLabel) }
    }

    static func settingEdited(_ edited: Bool, in content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        let headerEnd = lines.firstIndex { $0.hasPrefix("## ") } ?? lines.count
        let existing = lines[..<headerEnd].firstIndex { $0.hasPrefix(editedLabel) }
        switch (edited, existing) {
        case (true, nil):
            // Last metadata line of the header block, before its blank line.
            var at = headerEnd
            while at > 0, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert("\(editedLabel) yes", at: at)
        case (false, let index?):
            lines.remove(at: index)
        default:
            break
        }
        return lines.joined(separator: "\n")
    }

    private static func headerLines(_ content: String) -> [Substring] {
        var result: [Substring] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") { break }
            result.append(line)
        }
        return result
    }

    // MARK: - Home screen

    struct FollowUp: Identifiable, Equatable {
        let url: URL
        /// Position in the meeting's next steps; with `text`, identifies the
        /// line again when it's ticked (parsed ids aren't stable).
        let index: Int
        let text: String
        let meetingTitle: String
        let date: Date?
        var id: String { "\(url.lastPathComponent)#\(index)" }
    }

    struct MeetingStatus: Identifiable, Equatable {
        enum Kind: Equatable { case notesReady, noNotes }
        let url: URL
        let title: String
        let date: Date?
        let kind: Kind
        var id: String { url.lastPathComponent }
    }

    struct Attention: Equatable {
        var followUps: [FollowUp] = []
        var statuses: [MeetingStatus] = []
        var isEmpty: Bool { followUps.isEmpty && statuses.isEmpty }
    }

    /// Meetings whose notes the user has opened (file names). Lets home stop
    /// listing a meeting under "Notes to review" once looked at.
    static let openedKey = "openedMeetingNotes"

    static func markOpened(_ url: URL, defaults: UserDefaults = .standard) {
        var opened = defaults.stringArray(forKey: openedKey) ?? []
        guard !opened.contains(url.lastPathComponent) else { return }
        opened.append(url.lastPathComponent)
        defaults.set(Array(opened.suffix(500)), forKey: openedKey)
    }

    /// What needs attention, from files only. Follow-ups: unticked next steps
    /// from the last `followUpDays` (two weeks by default; older notes formats parse the same way:
    /// unchecked "Suggested Next Steps" lines count as open). Statuses: the
    /// last `statusDays` of meetings with notes not yet opened, or no AI
    /// notes (no topic sections) yet.
    static func attention(files: [URL], opened: Set<String>, now: Date = Date(),
                          followUpDays: Int = 14, statusDays: Int = 7,
                          maxFiles: Int = 60,
                          read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) },
                          title: (URL, String) -> String) -> Attention {
        var result = Attention()
        let followUpCutoff = now.addingTimeInterval(-Double(followUpDays) * 86_400)
        let statusCutoff = now.addingTimeInterval(-Double(statusDays) * 86_400)
        for url in files.prefix(maxFiles) {
            let date = TranscriptSearch.sessionDate(for: url)
            guard let date, date >= followUpCutoff else { continue }
            guard let content = read(url) else { continue }
            let name = title(url, content)
            let review = review(in: content)
            for (i, item) in (review?.actionItems ?? []).enumerated()
            where !item.isDone && !isTranscriptQuote(item.text) {
                result.followUps.append(FollowUp(url: url, index: i, text: item.text,
                                                 meetingTitle: name, date: date))
            }
            guard date >= statusCutoff else { continue }
            // A mis-click or test capture (a few lines) isn't worth notes.
            let spoken = content.split(separator: "\n").lazy
                .filter { TranscriptSearch.parseTranscriptLine(String($0)) != nil }
                .prefix(minTranscriptLines).count
            guard spoken >= minTranscriptLines else { continue }
            if let review, !review.sections.isEmpty {
                if !opened.contains(url.lastPathComponent) {
                    result.statuses.append(MeetingStatus(url: url, title: name, date: date, kind: .notesReady))
                }
            } else {
                result.statuses.append(MeetingStatus(url: url, title: name, date: date, kind: .noNotes))
            }
        }
        return result
    }

    static let minTranscriptLines = 6

    /// The basic recap (no AI) lists quoted "I'll…" lines as next steps,
    /// shaped `“quote” — Speaker, 01:23`. They are evidence, not tasks, and
    /// would flood the follow-up list from every meeting without AI notes.
    static func isTranscriptQuote(_ text: String) -> Bool {
        text.hasPrefix("“") && text.range(of: #"” — .+, \d{1,2}:\d{2}(:\d{2})?$"#,
                                          options: .regularExpression) != nil
    }

    /// Tick or untick one follow-up in its meeting file. Returns false when
    /// the line moved or changed since it was listed (nothing is written).
    @discardableResult
    static func setDone(_ followUp: FollowUp, _ done: Bool) -> Bool {
        guard let content = try? String(contentsOf: followUp.url, encoding: .utf8),
              var review = review(in: content),
              review.actionItems.indices.contains(followUp.index),
              review.actionItems[followUp.index].text == followUp.text else { return false }
        review.actionItems[followUp.index].isDone = done
        do {
            try replacingReview(in: content, with: review)
                .write(to: followUp.url, atomically: true, encoding: .utf8)
        } catch { return false }
        NotificationCenter.default.post(name: didChange, object: followUp.url)
        return true
    }
}
