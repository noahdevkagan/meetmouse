import Foundation

/// Opt-in coaching feedback (decisions.md 2026-11-02 "coaching feedback").
///
/// A SEPARATE toggle from usage counts, OFF by default (Settings → General →
/// "Help improve coaching"). When on, every nudge the user rated (useful /
/// annoying / wrong) is queued at session end as ids and numbers only:
/// the built-in signal key, the rating, the minute it fired, the meeting type,
/// and three numbers describing the moment — your talk share so far, your last
/// turn's length, and how many turns the call had. Never audio, transcripts,
/// notes, titles, names, or user-authored rubric ids (custom signals are sent
/// as the bare word "custom"). The queue is sent at most once a day to
/// meetmouse.com/api/feedback; the weekly improve workflow turns the
/// aggregate into bounded threshold tweaks (Engine/FieldTuning.swift).
///
/// Plain types only so tests/usage compiles this file standalone; the view
/// model maps Nudge/Turn onto RatedNudge/TurnSample.
struct FeedbackLedger {
    static let endpoint = URL(string: "https://meetmouse.com/api/feedback")!
    /// Unsent events older than this are dropped (the server rejects > 60).
    static let keepDays = 45
    /// Hard cap on the local queue, and the server's per-report maximum.
    static let maxQueued = 2000
    static let maxPerReport = 500
    /// Below this many labeled words a talk share is noise, not a number.
    static let minShareWords = 40

    struct Features: Codable, Equatable {
        var youShare: Double?
        var lastYouTurnSec: Double?
        var turnsSoFar: Int?
    }

    struct Event: Codable, Equatable {
        var eventId: String
        var day: String
        var signal: String
        var rating: String
        var minute: Int
        var meetingType: String
        var features: Features
    }

    struct Report: Codable, Equatable {
        var installId: String
        var appVersion: String
        var events: [Event]
    }

    /// One rated nudge, as plain values.
    struct RatedNudge {
        var signalKey: String      // Nudge.typeKey
        var rating: String         // NudgeFeedback.rawValue
        var timestamp: TimeInterval
    }

    /// One coalesced speaker turn, as plain values.
    struct TurnSample {
        var isYou: Bool
        /// "Meeting" turns (mixed stream, no you/them split) are skipped for share.
        var isStructural: Bool
        var t: TimeInterval
        var endT: TimeInterval
        var words: Int
    }

    enum Key {
        static let optedIn = "shareCoachingFeedback"
        static let installId = "coachingFeedback.installId"
        static let events = "coachingFeedback.events"
        static let lastSentAt = "coachingFeedback.lastSentAt"
    }

    static let ratings: Set<String> = ["useful", "annoying", "wrong"]

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

    /// Returns the install id that was removed on opt-out (so the caller can
    /// ask the server to delete its rows), nil otherwise.
    @discardableResult
    func setOptedIn(_ on: Bool) -> String? {
        defaults.set(on, forKey: Key.optedIn)
        if on {
            if installId == nil { defaults.set(UUID().uuidString, forKey: Key.installId) }
            return nil
        }
        let removed = installId
        defaults.removeObject(forKey: Key.installId)
        defaults.removeObject(forKey: Key.events)
        defaults.removeObject(forKey: Key.lastSentAt)
        return removed
    }

    var pending: [Event] {
        guard let data = defaults.data(forKey: Key.events),
              let events = try? JSONDecoder().decode([Event].self, from: data) else { return [] }
        return events
    }

    var pendingCount: Int { pending.count }

    /// "Delete all" in Settings: drops the unsent queue, stays opted in.
    func deletePending() { defaults.removeObject(forKey: Key.events) }

    private func save(_ events: [Event]) {
        if events.isEmpty {
            defaults.removeObject(forKey: Key.events)
        } else if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: Key.events)
        }
    }

    func dayString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// User-authored rubric ids are text the user wrote: never send them.
    static func reportedSignal(_ typeKey: String) -> String {
        typeKey.hasPrefix("custom") ? "custom" : typeKey
    }

    /// The moment a nudge fired, as three coarse numbers (rounded so they
    /// describe the situation without fingerprinting the call).
    static func features(at t: TimeInterval, turns: [TurnSample]) -> Features {
        var youWords = 0, themWords = 0, count = 0
        var lastYou: TurnSample?
        for turn in turns where turn.t <= t {
            count += 1
            if turn.isYou { lastYou = turn }
            guard !turn.isStructural || turn.isYou else { continue }
            if turn.isYou { youWords += turn.words } else { themWords += turn.words }
        }
        var share: Double?
        if youWords > 0, youWords + themWords >= minShareWords {
            share = (Double(youWords) / Double(youWords + themWords) * 100).rounded() / 100
        }
        let lastLength = lastYou.map { (min(max(0, min($0.endT, t) - $0.t), 3600) * 10).rounded() / 10 }
        return Features(youShare: share, lastYouTurnSec: lastLength, turnsSoFar: min(count, 5000))
    }

    /// Queues every rated nudge from a finished meeting. No-op unless opted in.
    func record(_ rated: [RatedNudge], meetingType: String, turns: [TurnSample]) {
        guard isOptedIn else { return }
        let today = dayString(now())
        let fresh = rated.filter { Self.ratings.contains($0.rating) }.map { nudge in
            Event(eventId: UUID().uuidString, day: today,
                  signal: Self.reportedSignal(nudge.signalKey), rating: nudge.rating,
                  minute: min(max(0, Int(nudge.timestamp / 60)), 600), meetingType: meetingType,
                  features: Self.features(at: nudge.timestamp, turns: turns))
        }
        guard !fresh.isEmpty else { return }
        let cutoff = dayString(now().addingTimeInterval(-Double(Self.keepDays) * 86_400))
        save(Array((pending + fresh).filter { $0.day >= cutoff }.suffix(Self.maxQueued)))
    }

    /// The report to send now, or nil: at most once every 24 hours.
    func dueReport(appVersion: String) -> Report? {
        guard isOptedIn, let installId else { return nil }
        if let last = defaults.object(forKey: Key.lastSentAt) as? Date,
           now().timeIntervalSince(last) < 86_400 { return nil }
        let queued = pending
        guard !queued.isEmpty else { return nil }
        return Report(installId: installId, appVersion: appVersion,
                      events: Array(queued.prefix(Self.maxPerReport)))
    }

    /// Accepted (2xx) or permanently rejected (4xx except 429): forget those
    /// events so a bad one can't retry forever.
    func markSent(_ report: Report) {
        guard isOptedIn, installId == report.installId else { return }
        let sent = Set(report.events.map(\.eventId))
        save(pending.filter { !sent.contains($0.eventId) })
        defaults.set(now(), forKey: Key.lastSentAt)
    }
}

/// Network side. Called at launch, after each meeting, and on opt-out.
enum FeedbackReporter {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func record(_ rated: [FeedbackLedger.RatedNudge], meetingType: String,
                       turns: [FeedbackLedger.TurnSample]) {
        guard FeedbackLedger.isAllowedInThisBuild else { return }
        FeedbackLedger(defaults: .standard).record(rated, meetingType: meetingType, turns: turns)
    }

    static func sendIfDue() async {
        guard FeedbackLedger.isAllowedInThisBuild else { return }
        let ledger = FeedbackLedger(defaults: .standard)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard let report = ledger.dueReport(appVersion: version),
              let body = try? JSONEncoder().encode(report) else { return }
        var request = URLRequest(url: FeedbackLedger.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let result = try? await session.data(for: request),
              let status = (result.1 as? HTTPURLResponse)?.statusCode else { return }
        if (200..<300).contains(status) || ((400..<500).contains(status) && status != 429) {
            FeedbackLedger(defaults: .standard).markSent(report)
        }
    }

    /// Opt-out: ask the server to delete what this install sent. Best effort;
    /// anything left is purged after 180 days regardless.
    static func deleteRemote(installId: String) async {
        guard FeedbackLedger.isAllowedInThisBuild,
              let url = URL(string: FeedbackLedger.endpoint.absoluteString + "/" + installId) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await session.data(for: request)
    }
}
