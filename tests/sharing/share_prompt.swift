import Foundation

// "Send these notes?" card: fresh meetings with real notes only, once per
// meeting, and silent for good after 3 dismissals in a row.
@main
struct SharePromptCheck {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "  ok  \(name)" : "  FAIL \(name)")
        if !ok { failures += 1 }
    }

    static func main() {
        let suite = "share-prompt-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let meetingAt = ISO8601DateFormatter().date(from: "2026-10-20T15:00:00Z")!
        var clock = meetingAt.addingTimeInterval(3600)
        var prompt = SharePrompt(defaults: defaults)
        prompt.now = { clock }
        func shows(_ id: String, notes: Bool = true, shared: Bool = false, date: Date? = meetingAt) -> Bool {
            prompt.shouldShow(meeting: id, meetingDate: date, hasShareableNotes: notes, alreadyShared: shared)
        }

        check(shows("a.md"), "fresh meeting with notes shows the card")
        check(!shows("a.md", notes: false), "no card without real AI notes")
        check(!shows("a.md", shared: true), "no card once a link exists")
        check(!shows("a.md", date: nil), "no card when the meeting date is unknown")
        clock = meetingAt.addingTimeInterval(25 * 3600)
        check(!shows("a.md"), "no card for meetings older than a day")
        clock = meetingAt.addingTimeInterval(3600)

        prompt.recordDismissed(meeting: "a.md")
        check(!shows("a.md"), "dismissed meeting never asks again")
        check(shows("b.md"), "another meeting still asks")
        prompt.recordShared(meeting: "b.md")
        check(!shows("b.md") && prompt.dismissStreak == 0, "sharing handles the meeting and resets the streak")

        for id in ["c.md", "d.md"] { prompt.recordDismissed(meeting: id) }
        check(shows("e.md"), "2 dismissals in a row: still asks")
        prompt.recordDismissed(meeting: "e.md")
        check(!shows("f.md"), "3 dismissals in a row: stops asking")

        print(failures == 0 ? "share prompt: all checks passed" : "share prompt: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
