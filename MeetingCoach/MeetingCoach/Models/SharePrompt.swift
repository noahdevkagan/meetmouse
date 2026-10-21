import Foundation

/// The quiet "send these notes?" card on a just-finished meeting's Notes tab.
///
/// It asks at the one moment sharing is useful (right after the recap, while the
/// people in the meeting still want the next steps) and then gets out of the way:
/// - only for a meeting that ended in the last day and has real AI notes,
/// - only until the user shares or dismisses it for that meeting,
/// - never again after 3 dismissals in a row (sharing resets the streak).
/// It never posts anywhere; the button runs the normal Share notes action.
struct SharePrompt {
    static let dismissalsBeforeGivingUp = 3
    static let freshWindow: TimeInterval = 24 * 3600
    private static let rememberedMeetings = 200

    let defaults: UserDefaults
    var now: () -> Date = Date.init

    private enum Key {
        static let handled = "sharePrompt.handledMeetings"
        static let dismissStreak = "sharePrompt.dismissStreak"
    }

    var dismissStreak: Int { defaults.integer(forKey: Key.dismissStreak) }

    func shouldShow(meeting: String, meetingDate: Date?, hasShareableNotes: Bool, alreadyShared: Bool) -> Bool {
        guard hasShareableNotes, !alreadyShared,
              dismissStreak < Self.dismissalsBeforeGivingUp,
              !handled.contains(meeting),
              let meetingDate, now().timeIntervalSince(meetingDate) < Self.freshWindow
        else { return false }
        return true
    }

    func recordDismissed(meeting: String) {
        markHandled(meeting)
        defaults.set(dismissStreak + 1, forKey: Key.dismissStreak)
    }

    /// Any share, from the card or the regular Share notes button, counts.
    func recordShared(meeting: String) {
        markHandled(meeting)
        defaults.set(0, forKey: Key.dismissStreak)
    }

    private var handled: [String] { defaults.stringArray(forKey: Key.handled) ?? [] }

    private func markHandled(_ meeting: String) {
        var list = handled.filter { $0 != meeting }
        list.append(meeting)
        defaults.set(Array(list.suffix(Self.rememberedMeetings)), forKey: Key.handled)
    }
}
