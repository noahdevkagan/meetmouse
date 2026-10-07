import Foundation

/// Why the user's side of the meeting isn't being heard.
struct MicWarning: Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        /// macOS microphone access is off for MeetMouse. Capture still
        /// "runs" — the system just hands the app silence.
        case permissionDenied
        /// Access is fine but the input device delivers nothing: the
        /// built-in mic with the lid closed, a disconnected default input.
        case noSignal
    }
    let cause: Cause
    /// The input device capture was reading, when known.
    let deviceName: String?
}

/// Decides when a session's microphone has been digitally silent long enough
/// to tell the user. A live room never reads exactly zero, so all-zero audio
/// means MeetMouse can't hear the mic at all — seen in the field for whole
/// meetings, every meeting, while the zero-audio watchdog quietly rebuilt
/// capture every 9 s (2026-10-07: 1,831 rebuilds, zero "You" lines, no
/// warning). Rebuilds deliberately don't restart the clock: what matters is
/// how long the session has gone without hearing the user.
///
/// Exact zero is also what a hardware-muted mic (a USB mic's mute button,
/// input volume at 0) delivers, so a deliberately muted user can see this
/// too — the UI lets them dismiss it until the mic is heard again.
struct MicSilenceMonitor {
    static let warnAfter: TimeInterval = 30

    private(set) var warning: MicWarning.Cause?
    private var silentSince: Date?

    init(start: Date) {
        silentSince = start
    }

    /// Per mic buffer — and with `nonzero: false` at the last buffer's time
    /// when buffers stop arriving altogether (a dead device delivers none,
    /// not zeros). Returns true when the warning state changed.
    mutating func observe(nonzero: Bool, at now: Date) -> Bool {
        if nonzero {
            silentSince = nil
            guard warning != nil else { return false }
            warning = nil
            return true
        }
        if silentSince == nil { silentSince = now }
        return false
    }

    /// Periodic check. `suppressed` while an Apple call holds the mic (macOS
    /// zeroes it on purpose; no mic setting can fix that). Permission is
    /// re-read every check: the system prompt can be answered mid-session.
    /// Returns true when the warning state changed.
    mutating func evaluate(now: Date, suppressed: Bool, permissionDenied: Bool) -> Bool {
        let next: MicWarning.Cause?
        if suppressed {
            next = nil
        } else if let since = silentSince {
            // Denied access is certain from the first second; a merely
            // silent device gets the grace period (it may be warming up,
            // or the user is muted and quiet).
            next = permissionDenied ? .permissionDenied
                : now.timeIntervalSince(since) >= Self.warnAfter ? .noSignal : nil
        } else {
            next = nil
        }
        guard next != warning else { return false }
        warning = next
        return true
    }
}
