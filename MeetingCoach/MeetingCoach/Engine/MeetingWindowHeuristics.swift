import Foundation

/// A window snapshot row the heuristics reason over. The service fills
/// these from CGWindowListCopyWindowInfo; kept Foundation-only so the
/// heuristics compile into the detector test binary.
struct WindowInfo: Sendable {
    var ownerName: String
    var title: String
    /// Bundle id of the owning process when the sampler could resolve it
    /// (CGWindowList owner PID → NSRunningApplication; SCK owning app).
    /// Owner NAMES drift across app versions — Zoom 7 renamed its process
    /// from "zoom.us" to "Zoom", which silently blinded the end-watch for
    /// every Zoom call (2026-10-09) — so matching prefers the bundle id
    /// and keeps the name as a fallback for samplers that lack it.
    var ownerBundleID: String? = nil
}

/// Pure title/owner matching that turns a window-list snapshot into the
/// tri-state `MeetingSignals.meetingWindowPresent`. English titles only —
/// a localized miss is safe because the detector only trusts absence
/// after it has seen a window at least once (`windowSeen` latch).
enum MeetingWindowHeuristics {
    /// Browser owner names whose window title reflects the active tab.
    static let browserOwners: Set<String> = [
        "Safari", "Google Chrome", "Firefox", "Microsoft Edge", "Brave Browser",
        "Arc", "Vivaldi", "Opera", "Chromium", "Dia", "Comet", "Kagi",
    ]

    /// - Parameters:
    ///   - windows: full window-list snapshot (all Spaces, so minimized or
    ///     other-Space meeting windows don't read as absent).
    ///   - zoomRunning/slackRunning: the app process is alive, so "no
    ///     matching window" is decisive absence for that platform.
    ///   - micHolderIsBrowser: the live meeting's mic evidence came from a
    ///     browser (or is unknown). Browser titles only show the active
    ///     tab, so a missing Meet title is never decisive — the user may
    ///     just have tabbed away.
    /// - Returns: true = meeting window on screen; false = decisively
    ///   absent; nil = can't tell.
    static func evaluate(windows: [WindowInfo],
                         zoomRunning: Bool, slackRunning: Bool,
                         micHolderIsBrowser: Bool) -> Bool? {
        for w in windows {
            if isZoomMeetingWindow(w) || isSlackHuddleWindow(w)
                || isMeetTabWindow(w) || isHangoutsTabWindow(w)
                || isFaceTimeCallWindow(w) {
                return true
            }
        }
        // No positive match. Only Zoom/Slack absence is decisive (their
        // meeting windows are real windows, not tabs), and only when the
        // meeting's mic isn't held by a browser.
        if (zoomRunning || slackRunning) && !micHolderIsBrowser {
            return false
        }
        return nil
    }

    /// Owner names Zoom has shipped under: "zoom.us" (≤ 6.x) and "Zoom"
    /// (Zoom Workplace 7.x). Bundle id "us.zoom.xos" has stayed constant.
    static let zoomOwnerNames: Set<String> = ["zoom.us", "Zoom", "Zoom Workplace"]

    static func isZoomOwned(_ w: WindowInfo) -> Bool {
        owned(w, bundlePrefix: "us.zoom.xos", names: zoomOwnerNames)
    }

    static func isSlackOwned(_ w: WindowInfo) -> Bool {
        owned(w, bundlePrefix: "com.tinyspeck.slackmacgap", names: ["Slack"])
    }

    static func isFaceTimeOwned(_ w: WindowInfo) -> Bool {
        owned(w, bundlePrefix: "com.apple.FaceTime", names: ["FaceTime"])
    }

    /// Bundle id decides when known; otherwise the owner name. A resolved
    /// bundle id that belongs to another app must NOT fall through to the
    /// name check ("Notes" titled "Zoom Meeting" stays non-meeting).
    private static func owned(_ w: WindowInfo, bundlePrefix: String, names: Set<String>) -> Bool {
        if let id = w.ownerBundleID, !id.isEmpty {
            return id == bundlePrefix || id.hasPrefix(bundlePrefix + ".")
        }
        return names.contains(w.ownerName)
    }

    static func isZoomMeetingWindow(_ w: WindowInfo) -> Bool {
        isZoomOwned(w)
            && (w.title.hasPrefix("Zoom Meeting") || w.title.hasPrefix("Zoom Webinar"))
    }

    static func isSlackHuddleWindow(_ w: WindowInfo) -> Bool {
        isSlackOwned(w) && w.title.localizedCaseInsensitiveContains("huddle")
    }

    /// FaceTime's idle window is titled "FaceTime"; during a call (FaceTime
    /// or an iPhone-relayed cellular call) the window title is the caller's
    /// name — which is also the best session title we'll ever get.
    static func isFaceTimeCallWindow(_ w: WindowInfo) -> Bool {
        isFaceTimeOwned(w) && !w.title.isEmpty && w.title != "FaceTime"
    }

    static func isMeetTabWindow(_ w: WindowInfo) -> Bool {
        guard browserOwners.contains(w.ownerName) else { return false }
        // Meet tab titles: "Meet – xyz-abcd-ef" (en dash) or hyphen variant.
        // Case-insensitive — browsers/extensions sometimes re-case titles.
        let title = w.title.lowercased()
        return title.hasPrefix("meet – ") || title.hasPrefix("meet - ")
            || title.contains("meet.google.com")
    }

    /// Google Hangouts (legacy/classic titles still seen in the wild, plus
    /// the hangouts.google.com redirect page a Meet can open from).
    static func isHangoutsTabWindow(_ w: WindowInfo) -> Bool {
        guard browserOwners.contains(w.ownerName) else { return false }
        let title = w.title.lowercased()
        return title.contains("hangouts.google.com") || title.hasPrefix("hangouts")
            || title.contains("google hangouts")
    }

    /// Best-effort human meeting NAME from the window snapshot — "Weekly
    /// Sync" out of a tab titled "Meet – Weekly Sync - Google Chrome".
    /// nil when every candidate is generic (bare "Zoom Meeting", a Meet
    /// room code) — a generic name is worse than letting the transcript
    /// heuristic title the session.
    static func meetingTitle(from windows: [WindowInfo]) -> String? {
        for w in windows {
            if isMeetTabWindow(w) || isHangoutsTabWindow(w) {
                if let t = cleanedBrowserMeetingTitle(w.title) { return t }
            }
            if isZoomMeetingWindow(w) {
                // Zoom titles are almost always the bare generic; anything
                // beyond it is the meeting topic.
                let t = w.title
                    .replacingOccurrences(of: "Zoom Meeting", with: "")
                    .replacingOccurrences(of: "Zoom Webinar", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:"))
                if !t.isEmpty { return t }
            }
            if isSlackHuddleWindow(w) {
                let t = w.title.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return t }
            }
            if isFaceTimeCallWindow(w) {
                // The call window title is the caller's name.
                let t = w.title.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    /// "Meet – Weekly Sync - Google Chrome" → "Weekly Sync".
    static func cleanedBrowserMeetingTitle(_ raw: String) -> String? {
        var t = raw
        // Strip a trailing " - <Browser>" (any known browser, hyphen or
        // dash variants — Chrome uses " - ", Firefox " — ").
        for browser in browserOwners {
            for sep in [" - ", " – ", " — "] {
                if t.hasSuffix(sep + browser) {
                    t = String(t.dropLast(sep.count + browser.count))
                }
            }
        }
        // Strip the product prefix.
        for prefix in ["meet – ", "meet - ", "hangouts – ", "hangouts - "] {
            if t.lowercased().hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count))
            }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        // A bare Meet room code ("kgx-vrbo-abc") names nothing.
        if t.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil {
            return nil
        }
        if t.isEmpty || t.lowercased().contains("meet.google.com") { return nil }
        return t
    }

    /// Best-effort platform label for a browser-hosted meeting, from tab
    /// titles — nil when nothing gives it away (label stays generic).
    static func browserMeetingPlatform(_ windows: [WindowInfo]) -> String? {
        for w in windows {
            if isMeetTabWindow(w) { return "Google Meet" }
            if isHangoutsTabWindow(w) { return "Google Hangouts" }
            if browserOwners.contains(w.ownerName), w.title.lowercased().contains("zoom.us") {
                return "Zoom (browser)"
            }
        }
        return nil
    }
}
