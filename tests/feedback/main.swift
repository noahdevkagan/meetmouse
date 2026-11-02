import Foundation

// Opt-in coaching feedback (decisions.md 2026-11-02 "coaching feedback").
@main
struct FeedbackCheck {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "  ok  \(name)" : "  FAIL \(name)")
        if !ok { failures += 1 }
    }

    /// The only string-valued fields a report may carry: ids, version, and
    /// fixed vocabularies. Anything else could smuggle user text.
    static let allowedStringKeys: Set<String> = [
        "installId", "appVersion", "eventId", "day", "signal", "rating", "meetingType",
    ]

    static func stringKeys(_ value: Any, key: String? = nil, into out: inout [String]) {
        if let dict = value as? [String: Any] {
            for (k, v) in dict { stringKeys(v, key: k, into: &out) }
        } else if let array = value as? [Any] {
            for v in array { stringKeys(v, key: key, into: &out) }
        } else if value is String {
            out.append(key ?? "?")
        }
    }

    static func main() {
        let suite = "feedback-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var clock = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!
        var ledger = FeedbackLedger(defaults: defaults)
        ledger.now = { clock }
        ledger.calendar = calendar

        let turns: [FeedbackLedger.TurnSample] = [
            .init(isYou: true, isStructural: false, t: 0, endT: 90, words: 60),
            .init(isYou: false, isStructural: false, t: 95, endT: 120, words: 20),
            .init(isYou: true, isStructural: false, t: 125, endT: 400, words: 120),
        ]
        let rated: [FeedbackLedger.RatedNudge] = [
            .init(signalKey: "talkTime", rating: "annoying", timestamp: 300),
            .init(signalKey: "custom:acme_pricing_objection", rating: "useful", timestamp: 61),
            .init(signalKey: "nextSteps", rating: "ignored", timestamp: 10),
        ]

        check(!ledger.isOptedIn && ledger.installId == nil, "off by default, no install id")
        ledger.record(rated, meetingType: "salesCall", turns: turns)
        check(ledger.pendingCount == 0, "nothing queued while off")
        check(ledger.dueReport(appVersion: "0.34.0") == nil, "nothing to send while off")

        ledger.setOptedIn(true)
        let firstID = ledger.installId
        check(ledger.isOptedIn && firstID != nil, "opt-in mints an install id")
        ledger.record(rated, meetingType: "salesCall", turns: turns)
        let queued = ledger.pending
        check(queued.count == 2, "only real ratings are queued (unknown rating dropped)")
        check(queued.map(\.signal) == ["talkTime", "custom"], "custom rubric ids are reduced to \"custom\"")
        check(queued[0].minute == 5 && queued[0].meetingType == "salesCall", "minute and meeting type recorded")
        check(queued[0].features.youShare == 0.9 && queued[0].features.turnsSoFar == 3,
              "talk share and turn count at the moment it fired")
        check(queued[0].features.lastYouTurnSec == 175, "last turn length is cut at the fire time")
        check(queued[1].features.youShare == 1.0 && queued[1].features.lastYouTurnSec == 61,
              "share needs 40 words; the first turn alone qualifies")

        guard let report = ledger.dueReport(appVersion: "0.34.0") else {
            check(false, "queued ratings are due"); exit(1)
        }
        let json = try! JSONEncoder().encode(report)
        let object = try! JSONSerialization.jsonObject(with: json)
        var keys: [String] = []
        stringKeys(object, into: &keys)
        let unexpected = Set(keys).subtracting(allowedStringKeys)
        check(unexpected.isEmpty, "payload strings are ids/vocab only (unexpected: \(unexpected.sorted()))")
        let text = String(data: json, encoding: .utf8)!
        check(!text.contains("acme"), "no user-authored text leaks into the payload")

        ledger.markSent(report)
        check(ledger.pendingCount == 0, "sent events are cleared")
        ledger.record(rated, meetingType: "general", turns: turns)
        check(ledger.dueReport(appVersion: "0.34.0") == nil, "at most one send per 24 hours")
        clock = clock.addingTimeInterval(86_401)
        check(ledger.dueReport(appVersion: "0.34.0") != nil, "due again the next day")

        ledger.deletePending()
        check(ledger.pendingCount == 0 && ledger.isOptedIn, "Delete all empties the queue, stays opted in")

        ledger.record(rated, meetingType: "general", turns: turns)
        let removed = ledger.setOptedIn(false)
        check(removed == firstID, "opt-out hands back the id so the server can delete its rows")
        check(ledger.installId == nil && ledger.pendingCount == 0, "opt-out wipes the id and the queue")
        ledger.setOptedIn(true)
        check(ledger.installId != firstID, "re-opting starts a new, unlinked identity")

        // Stale report from the old identity must not clear the new queue.
        ledger.record(rated, meetingType: "general", turns: turns)
        ledger.markSent(report)
        check(ledger.pendingCount == 2, "a late response for an old identity changes nothing")

        // Field tuning table: inside the clamp, and an empty table is identity.
        for (key, value) in FieldTuning.multipliers {
            check(FieldTuning.clampRange.contains(value), "field tuning \(key)=\(value) inside clamp")
        }
        check(FieldTuning.multiplier(forKey: "noSuchSignal") == 1.0, "unknown signal = no change")
        let stock: RubricTuning = ["talkTime": SignalTuning(enabled: true, thresholdMultiplier: 1.5, cooldownMultiplier: 2.0)]
        let applied = FieldTuning.applied(to: stock)
        let expected = 1.5 * FieldTuning.multiplier(forKey: "talkTime")
        let expectedCooldown = 2.0 * FieldTuning.multiplier(forKey: "talkTime")
        check(applied["talkTime"]?.thresholdMultiplier == expected
              && applied["talkTime"]?.cooldownMultiplier == expectedCooldown
              && applied["talkTime"]?.enabled == true,
              "field multiplier scales threshold and cooldown, keeps enabled")
        check(FieldTuning.applied(to: [:]).isEmpty == FieldTuning.multipliers.isEmpty,
              "empty field table leaves the rubric untouched")

        if failures > 0 {
            print("feedback: \(failures) FAILED"); exit(1)
        }
        print("feedback: all checks passed")
    }
}
