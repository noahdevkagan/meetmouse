import Foundation

/// Whether the call is playing out loud through the Mac's own speakers.
///
/// Field reports (Oct 2026, v0.31 to v0.33, three users on MacBook
/// speakers): the far side's words land in "You" lines and both sides blend
/// into one block. Voice processing is deliberately off (it ducks the call,
/// see AudioCaptureManager.startMicEngine), so on open speakers the mic hears
/// the far side at speech level. The bleed gate keys on absolute mic energy
/// (bleed is loud, so it never fires mid-bleed) and EchoFilter is a text
/// match that loses degraded echo and races the far side's partials. There
/// is no reliable software split for that case today, so MeetMouse says so:
/// a one-line live notice suggesting headphones.
///
/// Pure logic: the Core Audio reads live in AudioCaptureManager. Four-char
/// codes are spelled out so this file compiles without CoreAudio (tests).
enum OutputRoute {
    /// kAudioDeviceTransportTypeBuiltIn ('bltn').
    static let builtInTransport: UInt32 = 0x626C_746E
    /// Built-in output data source: internal speaker ('ispk').
    static let internalSpeakerSource: UInt32 = 0x6973_706B
    /// Built-in output data source: headphone jack ('hdpn').
    static let headphoneSource: UInt32 = 0x6864_706E

    /// True when the default output is the Mac's built-in speakers.
    /// `dataSource` is nil when the device doesn't report one: built-in
    /// output without a data source is still the speakers (iMac, Mac mini).
    /// Wired headphones in a MacBook's jack keep the built-in device but
    /// switch its data source to 'hdpn'. External, USB, Bluetooth and
    /// virtual devices are not flagged: they may be headphones.
    static func isBuiltInSpeakers(transport: UInt32, dataSource: UInt32?) -> Bool {
        guard transport == builtInTransport else { return false }
        return dataSource != headphoneSource
    }
}

/// Live-session state for the "use headphones" notice. Shown only while
/// both channels are captured (in mic-only sessions speakers are the
/// supported setup, and there is no You/Them split to protect) and the
/// output is the built-in speakers. Dismissal lasts for the session.
struct SpeakerBleedNotice: Equatable {
    private(set) var onSpeakers = false
    private(set) var dismissed = false

    mutating func update(onSpeakers: Bool) { self.onSpeakers = onSpeakers }
    mutating func dismiss() { dismissed = true }

    func isVisible(micOnly: Bool) -> Bool {
        onSpeakers && !dismissed && !micOnly
    }
}
