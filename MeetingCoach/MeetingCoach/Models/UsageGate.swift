import CryptoKit
import Foundation
import Observation

/// Free tier: unlimited for the first week, then 3 meetings per week
/// (resets Monday). Inviting 2 friends, the $20 purchase code, or an
/// AppSumo code unlocks it for good. Same shape as Rhino's UsageGate.
///
/// Local-only and honor-based on purpose: counts live in preferences, codes
/// are checked against bundled SHA-256 hashes, nothing is sent anywhere.
/// Only *starting* a meeting is ever refused — saved notes, transcripts,
/// search and chat stay open forever. Installs that were already in use
/// before the free tier shipped are grandfathered.
struct UsageGate {
    static let weeklyFreeMeetings = 3
    static let trialDays = 7
    /// SHA-256 of the normalized code shown on meetmouse.com/thanks after purchase.
    static let purchaseCodeHash = "7939292c747f50bc22870eea0bdc9819a6f1d7a613e9bb2077663c57fbaea678"

    let defaults: UserDefaults
    var now: () -> Date = Date.init

    private enum Key {
        static let installedAt = "usage.installedAt"
        static let unlocked = "usage.unlocked"
        static let weekStart = "usage.weekStart"
        static let weekMeetings = "usage.weekMeetings"
        static let trialEndNoticeShown = "usage.trialEndNoticeShown"
    }

    /// Runs once per install, at launch. An install that already has saved
    /// meetings or finished the welcome sheet predates the free tier (the
    /// app was paid-only), so it is unlocked.
    func bootstrap(isExistingInstall: Bool) {
        guard defaults.object(forKey: Key.installedAt) == nil else { return }
        defaults.set(now(), forKey: Key.installedAt)
        if isExistingInstall { defaults.set(true, forKey: Key.unlocked) }
    }

    var isUnlocked: Bool { defaults.bool(forKey: Key.unlocked) }

    var trialEndsAt: Date? {
        guard let installedAt = defaults.object(forKey: Key.installedAt) as? Date else { return nil }
        return installedAt.addingTimeInterval(Double(Self.trialDays) * 86_400)
    }

    var isInTrial: Bool {
        guard let trialEndsAt else { return true }
        return now() < trialEndsAt
    }

    var meetingsThisWeek: Int {
        guard let start = defaults.object(forKey: Key.weekStart) as? Date,
              start == Self.weekStart(for: now()) else { return 0 }
        return defaults.integer(forKey: Key.weekMeetings)
    }

    var meetingsLeftThisWeek: Int { max(0, Self.weeklyFreeMeetings - meetingsThisWeek) }

    /// One-time heads-up that the free week is over, so the first refused
    /// meeting isn't the first time someone hears about the weekly limit.
    var shouldShowTrialEndedNotice: Bool {
        trialEndsAt != nil && !isUnlocked && !isInTrial && !defaults.bool(forKey: Key.trialEndNoticeShown)
    }

    func markTrialEndedNoticeShown() {
        defaults.set(true, forKey: Key.trialEndNoticeShown)
    }

    /// True when a new meeting should be refused. A meeting already in
    /// progress always finishes; only the next one is blocked.
    var isBlocked: Bool {
        !isUnlocked && !isInTrial && meetingsThisWeek >= Self.weeklyFreeMeetings
    }

    func recordMeeting() {
        // Trial meetings are free and don't eat into the week the trial ends in.
        guard !isInTrial else { return }
        // Read before stamping the week: stamping first would make last
        // week's count look like this week's.
        let total = meetingsThisWeek + 1
        defaults.set(Self.weekStart(for: now()), forKey: Key.weekStart)
        defaults.set(total, forKey: Key.weekMeetings)
    }

    /// Returns true and unlocks when the code is the purchase code or an AppSumo code.
    @discardableResult
    func unlock(code: String, appSumoHashes: Set<String>) -> Bool {
        let normalized = Self.normalize(code)
        guard !normalized.isEmpty else { return false }
        let digest = Self.sha256(normalized)
        guard digest == Self.purchaseCodeHash || appSumoHashes.contains(digest) else { return false }
        defaults.set(true, forKey: Key.unlocked)
        return true
    }

    /// Same normalization as the website's AppSumo redeem form.
    static func normalize(_ code: String) -> String {
        code.uppercased().filter { !$0.isWhitespace }
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Monday 00:00 local time of the week containing `date`.
    static func weekStart(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// Bundled AppSumo code hashes (docs/appsumo-hashes.json, the same list
    /// the website's redeem form uses).
    static func loadAppSumoHashes(bundle: Bundle = .main) -> Set<String> {
        guard let url = bundle.url(forResource: "appsumo-hashes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let hashes = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(hashes)
    }
}

/// Observable face of `UsageGate` for SwiftUI: views read through it so the
/// sidebar card and limit sheet update the moment a meeting is counted or
/// the app is unlocked.
@MainActor @Observable
final class FreeTier {
    static let shared = FreeTier()

    private(set) var gate = UsageGate(defaults: .standard)
    /// Bumped on every change so views reading computed gate state re-render.
    private(set) var revision = 0
    /// Set when a start was refused; ContentView shows the unlock sheet.
    var showLimitReached = false
    /// Set once, the first time the app is opened after the free week ends.
    var showTrialEnded = false

    var isUnlocked: Bool { _ = revision; return gate.isUnlocked }
    var isInTrial: Bool { _ = revision; return gate.isInTrial }
    var isBlocked: Bool { _ = revision; return gate.isBlocked }
    var meetingsLeftThisWeek: Int { _ = revision; return gate.meetingsLeftThisWeek }

    var trialDaysLeft: Int {
        _ = revision
        guard let end = gate.trialEndsAt else { return UsageGate.trialDays }
        return max(0, Int(ceil(end.timeIntervalSinceNow / 86_400)))
    }

    var referral: ReferralLink { ReferralLink(defaults: .standard) }

    func bootstrap() {
        let existing = UserDefaults.standard.bool(forKey: "hasSeenDemo")
            || !TranscriptSearch.sessionFiles().isEmpty
        gate.bootstrap(isExistingInstall: existing)
        revision += 1
    }

    /// Called before any real (non-demo) meeting starts. Returns false and
    /// raises the unlock sheet when the weekly allowance is used up.
    func allowMeetingStart() -> Bool {
        revision += 1
        guard gate.isBlocked else { return true }
        // The limit sheet says it all; don't follow it with the trial notice.
        gate.markTrialEndedNoticeShown()
        showLimitReached = true
        return false
    }

    /// Raises the one-time "free week is over" sheet when it's due. Called
    /// when the main window appears and whenever the app comes to the front,
    /// never during a meeting.
    func checkTrialEnded(isLive: Bool) {
        revision += 1
        guard !isLive, !showLimitReached, gate.shouldShowTrialEndedNotice else { return }
        gate.markTrialEndedNoticeShown()
        showTrialEnded = true
    }

    func recordMeeting() {
        gate.recordMeeting()
        revision += 1
    }

    @discardableResult
    func unlock(code: String) -> Bool {
        let ok = gate.unlock(code: code, appSumoHashes: UsageGate.loadAppSumoHashes())
        if ok {
            showLimitReached = false
            showTrialEnded = false
            revision += 1
        }
        return ok
    }

    /// meetmouse://unlock?code=… from the /thanks, /appsumo and referral status pages.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "meetmouse", url.host == "unlock",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else { return false }
        return unlock(code: code)
    }
}
