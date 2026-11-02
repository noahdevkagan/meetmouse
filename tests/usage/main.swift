import Foundation

// Opt-in anonymous usage counts (decisions.md 2026-11-02).
@main
struct UsageCheck {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "  ok  \(name)" : "  FAIL \(name)")
        if !ok { failures += 1 }
    }

    static func main() {
        let suite = "usage-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var clock = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!
        var ledger = UsageLedger(defaults: defaults)
        ledger.now = { clock }
        ledger.calendar = calendar

        check(!ledger.isOptedIn && ledger.installId == nil, "off by default, no install id")
        ledger.recordMeeting(seconds: 1800, nudges: 3)
        check(ledger.days.isEmpty, "nothing recorded while off")
        check(ledger.dueReport(appVersion: "0.34.0", osMajor: 15) == nil, "nothing to send while off")

        ledger.setOptedIn(true)
        let firstID = ledger.installId
        check(ledger.isOptedIn && firstID != nil, "opt-in mints an install id")
        ledger.recordMeeting(seconds: 1800, nudges: 3)
        ledger.recordMeeting(seconds: 20, nudges: 0)
        check(ledger.days == [.init(day: "2026-11-02", meetings: 2, meetingMinutes: 31, nudges: 3)],
              "meetings add into today's tally (minimum 1 minute each)")
        check(ledger.dueReport(appVersion: "0.34.0", osMajor: 15) == nil, "today is not sent while it is still being tallied")

        clock = clock.addingTimeInterval(86_400)
        ledger.recordMeeting(seconds: 600, nudges: 1)
        guard let report = ledger.dueReport(appVersion: "0.34.0", osMajor: 15) else {
            check(false, "yesterday is due the next day"); exit(1)
        }
        check(report.days.map(\.day) == ["2026-11-02"] && report.installId == firstID, "only completed days are sent")
        let json = String(data: try! JSONEncoder().encode(report), encoding: .utf8)!
        for key in ["installId", "appVersion", "osMajor", "days", "meetings", "meetingMinutes", "nudges"] {
            check(json.contains("\"\(key)\""), "payload uses the server's field name \(key)")
        }
        ledger.markSent(report)
        check(ledger.days.map(\.day) == ["2026-11-03"], "sent days are cleared, today is kept")
        clock = clock.addingTimeInterval(3600 * 20)
        ledger.recordMeeting(seconds: 600, nudges: 0)
        check(ledger.dueReport(appVersion: "0.34.0", osMajor: 15) == nil, "at most one report per 24 hours")

        ledger.setOptedIn(false)
        check(!ledger.isOptedIn && ledger.installId == nil && ledger.days.isEmpty,
              "opt-out deletes the id and every unsent day")
        ledger.markSent(report)
        check(defaults.object(forKey: UsageLedger.Key.lastSentAt) == nil, "an in-flight send can't write after opt-out")
        ledger.setOptedIn(true)
        check(ledger.installId != nil && ledger.installId != firstID, "opting back in starts a new identity")

        clock = clock.addingTimeInterval(Double(UsageLedger.keepDays + 5) * 86_400)
        ledger.recordMeeting(seconds: 60, nudges: 0)
        check(ledger.days.count == 1, "days older than the keep window are dropped")

        print(failures == 0 ? "usage: all checks passed" : "usage: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
