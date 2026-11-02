import Foundation

/// Opt-in anonymous usage counts (decisions.md 2026-11-02).
///
/// OFF by default (Settings → General → "Share anonymous usage counts").
/// When on, each finished meeting adds to a local per-day tally — meetings,
/// meeting minutes, nudges shown — and completed days are sent at most once
/// a day to meetmouse.com/api/usage with the app version, the macOS major
/// version and a random install ID. Nothing else: never audio, transcripts,
/// notes, titles, participants or rubric content.
///
/// The install ID is minted at opt-in and deleted (with any unsent days) at
/// opt-out, so turning it back on starts a new, unlinked identity. Debug
/// builds neither record nor send — dev and release share UserDefaults —
/// unless MEETMOUSE_USAGE_DEBUG=1 is set.
struct UsageLedger {
    static let endpoint = URL(string: "https://meetmouse.com/api/usage")!
    /// Unsent days older than this are dropped (the server rejects > 60).
    static let keepDays = 45

    struct Day: Codable, Equatable {
        var day: String
        var meetings: Int
        var meetingMinutes: Int
        var nudges: Int
    }

    struct Report: Codable, Equatable {
        var installId: String
        var appVersion: String
        var osMajor: Int
        var days: [Day]
    }

    enum Key {
        static let optedIn = "shareUsageStats"
        static let installId = "usageStats.installId"
        static let days = "usageStats.days"
        static let lastSentAt = "usageStats.lastSentAt"
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

    var isOptedIn: Bool {
        defaults.bool(forKey: Key.optedIn) && installId != nil
    }

    var installId: String? { defaults.string(forKey: Key.installId) }

    func setOptedIn(_ on: Bool) {
        defaults.set(on, forKey: Key.optedIn)
        if on {
            if installId == nil { defaults.set(UUID().uuidString, forKey: Key.installId) }
        } else {
            defaults.removeObject(forKey: Key.installId)
            defaults.removeObject(forKey: Key.days)
            defaults.removeObject(forKey: Key.lastSentAt)
        }
    }

    var days: [Day] {
        guard let data = defaults.data(forKey: Key.days),
              let days = try? JSONDecoder().decode([Day].self, from: data) else { return [] }
        return days
    }

    private func save(_ days: [Day]) {
        if days.isEmpty {
            defaults.removeObject(forKey: Key.days)
        } else if let data = try? JSONEncoder().encode(days) {
            defaults.set(data, forKey: Key.days)
        }
    }

    func dayString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Adds one finished meeting to today's tally. No-op unless opted in.
    func recordMeeting(seconds: TimeInterval, nudges: Int) {
        guard isOptedIn else { return }
        let today = dayString(now())
        let minutes = max(1, Int((seconds / 60).rounded()))
        var all = days
        if let index = all.firstIndex(where: { $0.day == today }) {
            all[index].meetings += 1
            all[index].meetingMinutes += minutes
            all[index].nudges += max(0, nudges)
        } else {
            all.append(Day(day: today, meetings: 1, meetingMinutes: minutes, nudges: max(0, nudges)))
        }
        let cutoff = dayString(now().addingTimeInterval(-Double(Self.keepDays) * 86_400))
        save(all.filter { $0.day >= cutoff })
    }

    /// The report to send now, or nil. Only completed days (before today) are
    /// sent — the server replaces a resent day, so sending a day still being
    /// tallied would later be overwritten by a partial count — and at most
    /// once every 24 hours.
    func dueReport(appVersion: String, osMajor: Int) -> Report? {
        guard isOptedIn, let installId else { return nil }
        if let last = defaults.object(forKey: Key.lastSentAt) as? Date,
           now().timeIntervalSince(last) < 86_400 { return nil }
        let today = dayString(now())
        let complete = days.filter { $0.day < today }.sorted { $0.day < $1.day }
        guard !complete.isEmpty else { return nil }
        return Report(installId: installId, appVersion: appVersion, osMajor: osMajor,
                      days: Array(complete.suffix(60)))
    }

    /// Server accepted (2xx) or permanently rejected (4xx other than 429):
    /// forget those days either way so a bad day can't retry forever.
    func markSent(_ report: Report) {
        // The user may have opted out (or out and back in) while the request
        // was in flight: never resurrect data for a different identity.
        guard isOptedIn, installId == report.installId else { return }
        let sent = Set(report.days.map(\.day))
        save(days.filter { !sent.contains($0.day) })
        defaults.set(now(), forKey: Key.lastSentAt)
    }
}

/// Sends the due report, if any. Called at launch and after each meeting.
enum UsageReporter {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func recordMeeting(seconds: TimeInterval, nudges: Int) {
        guard UsageLedger.isAllowedInThisBuild else { return }
        UsageLedger(defaults: .standard).recordMeeting(seconds: seconds, nudges: nudges)
    }

    static func sendIfDue() async {
        guard UsageLedger.isAllowedInThisBuild else { return }
        let ledger = UsageLedger(defaults: .standard)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard let report = ledger.dueReport(appVersion: version, osMajor: osMajor),
              let body = try? JSONEncoder().encode(report) else { return }

        var request = URLRequest(url: UsageLedger.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let result = try? await session.data(for: request),
              let status = (result.1 as? HTTPURLResponse)?.statusCode else { return }
        if (200..<300).contains(status) || ((400..<500).contains(status) && status != 429) {
            UsageLedger(defaults: .standard).markSent(report)
        }
    }
}
