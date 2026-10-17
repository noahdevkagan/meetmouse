import Foundation

// Free-tier gate: trial week, 3 meetings/week after, Monday reset,
// grandfathering, and code unlocks. Mirrors Rhino's UsageGate checks.
@main
struct FreeTierCheck {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "  ok  \(name)" : "  FAIL \(name)")
        if !ok { failures += 1 }
    }

    static func main() {
        let suite = "freetier-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let install = ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z")! // a Monday
        var clock = install
        var gate = UsageGate(defaults: defaults)
        gate.now = { clock }

        gate.bootstrap(isExistingInstall: false)
        check(!gate.isUnlocked && gate.isInTrial, "new install starts in trial, locked")
        for _ in 0..<10 { gate.recordMeeting() }
        check(!gate.isBlocked, "trial week is unlimited")

        clock = install.addingTimeInterval(8 * 86_400) // next Tuesday, trial over
        check(!gate.isInTrial && gate.meetingsThisWeek == 0, "new week resets the count")
        for _ in 0..<2 { gate.recordMeeting() }
        check(!gate.isBlocked && gate.meetingsLeftThisWeek == 1, "2 of 3 used: still allowed")
        gate.recordMeeting()
        check(gate.isBlocked, "4th meeting in a week is blocked")

        clock = install.addingTimeInterval(14 * 86_400 + 3600) // following Monday
        check(!gate.isBlocked, "Monday resets the allowance")

        check(!gate.unlock(code: "nope", appSumoHashes: []), "wrong code rejected")
        let appsumo = "AS-TEST-CODE"
        check(gate.unlock(code: " as-test-code ", appSumoHashes: [UsageGate.sha256(appsumo)]),
              "AppSumo code unlocks (normalized)")
        for _ in 0..<5 { gate.recordMeeting() }
        check(!gate.isBlocked, "unlocked is never blocked")

        let suite2 = suite + "-old"
        let old = UserDefaults(suiteName: suite2)!
        defer { old.removePersistentDomain(forName: suite2) }
        let grand = UsageGate(defaults: old)
        grand.bootstrap(isExistingInstall: true)
        check(grand.isUnlocked, "pre-free-tier install is grandfathered")
        grand.bootstrap(isExistingInstall: false)
        check(grand.isUnlocked, "bootstrap runs once")

        let suite3 = suite + "-buy"
        let buy = UserDefaults(suiteName: suite3)!
        defer { buy.removePersistentDomain(forName: suite3) }
        check(UsageGate(defaults: buy).unlock(code: "mouse-5kc5-7eda", appSumoHashes: []),
              "purchase code from /thanks unlocks")

        let link = ReferralLink(defaults: defaults)
        check(ReferralLink.isValid(link.code) && link.code == ReferralLink(defaults: defaults).code,
              "referral code is valid and stable")
        check(link.statusURL.absoluteString == "https://meetmouse.com/r/\(link.code)/status",
              "status URL on meetmouse.com")

        if failures > 0 { print("FREE TIER: \(failures) failure(s)"); exit(1) }
        print("FREE TIER: all checks passed")
    }
}
