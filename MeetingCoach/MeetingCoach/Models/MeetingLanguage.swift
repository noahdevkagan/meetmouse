import Foundation

/// The user's global meeting-language preference. `.system` deliberately
/// means the Mac's current language, not audio language detection. `.auto`
/// is the opt-in multi-language mode: Parakeet v3 with no script hint hears
/// any of its 25 languages, including several in one meeting.
enum MeetingLanguageSelection: String, CaseIterable, Codable, Identifiable, Sendable, Equatable {
    case system
    case auto
    case english = "en"
    case bulgarian = "bg"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case estonian = "et"
    case finnish = "fi"
    case french = "fr"
    case german = "de"
    case greek = "el"
    case hungarian = "hu"
    case italian = "it"
    case latvian = "lv"
    case lithuanian = "lt"
    case maltese = "mt"
    case polish = "pl"
    case portuguese = "pt"
    case romanian = "ro"
    case russian = "ru"
    case slovak = "sk"
    case slovenian = "sl"
    case spanish = "es"
    case swedish = "sv"
    case ukrainian = "uk"

    static let defaultsKey = "meetingLanguage"
    static let recentDefaultsKey = "recentMeetingLanguages"

    var id: String { rawValue }

    /// A concrete language, not a policy (Mac language / Auto-detect).
    var isSpecific: Bool { self != .system && self != .auto }

    /// The 25 concrete languages, in picker order.
    static var specificLanguages: [MeetingLanguageSelection] { allCases.filter(\.isSpecific) }

    /// Up to three concrete languages most recently chosen anywhere (Settings,
    /// sidebar, detection pill, live header), newest first. A multilingual
    /// user switches between the same few, so menus lead with these.
    static func recent(_ defaults: UserDefaults = .standard) -> [MeetingLanguageSelection] {
        let raw = defaults.stringArray(forKey: recentDefaultsKey) ?? []
        return raw.compactMap(Self.init(rawValue:)).filter(\.isSpecific)
    }

    /// Record a choice. Policies record the language they resolve to, so
    /// "Mac language (English)" still puts English one click away.
    static func noteUsed(_ language: MeetingLanguageSelection,
                         defaults: UserDefaults = .standard) {
        guard language.isSpecific else { return }
        var list = recent(defaults).filter { $0 != language }
        list.insert(language, at: 0)
        defaults.set(Array(list.prefix(3)).map(\.rawValue), forKey: recentDefaultsKey)
    }

    static var current: MeetingLanguageSelection {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let stored = MeetingLanguageSelection(rawValue: raw) else { return .system }
        return stored
    }

    var englishName: String {
        switch self {
        case .system: "Mac language"
        case .auto: "Auto-detect"
        case .english: "English"
        case .bulgarian: "Bulgarian"
        case .croatian: "Croatian"
        case .czech: "Czech"
        case .danish: "Danish"
        case .dutch: "Dutch"
        case .estonian: "Estonian"
        case .finnish: "Finnish"
        case .french: "French"
        case .german: "German"
        case .greek: "Greek"
        case .hungarian: "Hungarian"
        case .italian: "Italian"
        case .latvian: "Latvian"
        case .lithuanian: "Lithuanian"
        case .maltese: "Maltese"
        case .polish: "Polish"
        case .portuguese: "Portuguese"
        case .romanian: "Romanian"
        case .russian: "Russian"
        case .slovak: "Slovak"
        case .slovenian: "Slovenian"
        case .spanish: "Spanish"
        case .swedish: "Swedish"
        case .ukrainian: "Ukrainian"
        }
    }

    var nativeName: String {
        switch self {
        case .system: "Mac language"
        case .auto: "Auto-detect"
        case .english: "English"
        case .bulgarian: "Български"
        case .croatian: "Hrvatski"
        case .czech: "Čeština"
        case .danish: "Dansk"
        case .dutch: "Nederlands"
        case .estonian: "Eesti"
        case .finnish: "Suomi"
        case .french: "Français"
        case .german: "Deutsch"
        case .greek: "Ελληνικά"
        case .hungarian: "Magyar"
        case .italian: "Italiano"
        case .latvian: "Latviešu"
        case .lithuanian: "Lietuvių"
        case .maltese: "Malti"
        case .polish: "Polski"
        case .portuguese: "Português"
        case .romanian: "Română"
        case .russian: "Русский"
        case .slovak: "Slovenčina"
        case .slovenian: "Slovenščina"
        case .spanish: "Español"
        case .swedish: "Svenska"
        case .ukrainian: "Українська"
        }
    }

    var pickerName: String {
        if self == .auto { return "Auto-detect (any language)" }
        guard isSpecific, nativeName != englishName else { return englishName }
        return "\(nativeName) — \(englishName)"
    }

    /// Short name for chips and subtitles: what a meeting started now would
    /// listen for ("English" for Mac language on an English Mac).
    var quickName: String { resolved().language.englishName }

    /// Resolve once at meeting start. The locale identifier and the Apple
    /// Silicon gate are injectable so all supported, fallback, and Intel
    /// mappings are covered by a Foundation-only test without mutating the
    /// process locale or needing an Intel machine.
    ///
    /// Intel resolves to English whatever is selected: Parakeet v3 cannot run
    /// there at all (see PlatformSupport), so honoring the selection would
    /// only mean refusing to start every meeting. `selection` is preserved so
    /// Settings can say why the meeting is in English.
    func resolved(localeIdentifier: String = Locale.current.identifier,
                  neuralModelsSupported: Bool = PlatformSupport.neuralModelsSupported)
        -> ResolvedMeetingLanguage {
        let resolved = resolvedIgnoringPlatform(localeIdentifier: localeIdentifier)
        guard !neuralModelsSupported, !resolved.isEnglish else { return resolved }
        return ResolvedMeetingLanguage(selection: resolved.selection, language: .english,
                                       usedUnsupportedSystemFallback: false,
                                       intelFallbackFrom: resolved.language)
    }

    private func resolvedIgnoringPlatform(localeIdentifier: String) -> ResolvedMeetingLanguage {
        if self != .system {
            // `.auto` resolves to itself: the engine detects per window.
            return ResolvedMeetingLanguage(selection: self, language: self,
                                             usedUnsupportedSystemFallback: false)
        }
        let code = Locale(identifier: localeIdentifier).language.languageCode?.identifier
        if let code, let language = Self(rawValue: code), language.isSpecific {
            return ResolvedMeetingLanguage(selection: .system, language: language,
                                             usedUnsupportedSystemFallback: false)
        }
        return ResolvedMeetingLanguage(selection: .system, language: .english,
                                         usedUnsupportedSystemFallback: true)
    }

    /// Replay a saved session's language for review regeneration. Not gated on
    /// the platform: this reproduces what a past meeting was transcribed in,
    /// it never selects an engine. "auto" (multi-language or switched
    /// mid-call) returns nil, like legacy sessions: the notes language is
    /// re-detected from the transcript instead.
    static func resolvedPersistedCode(_ code: String) -> ResolvedMeetingLanguage? {
        guard let language = Self(rawValue: code), language.isSpecific else { return nil }
        return ResolvedMeetingLanguage(selection: language, language: language,
                                         usedUnsupportedSystemFallback: false)
    }
}

/// The actual transcription engine used for a session. Logic compares this
/// typed value; `displayLabel` is presentation and persisted diagnostics only.
enum TranscriptionEngine: String, Codable, Hashable, Sendable {
    case parakeetV2
    case parakeetV3
    case sfSpeech

    var isParakeet: Bool { self != .sfSpeech }

    func displayLabel(language: ResolvedMeetingLanguage) -> String {
        switch self {
        case .parakeetV2: "Parakeet v2 · \(language.englishName)"
        case .parakeetV3: "Parakeet v3 · \(language.englishName)"
        case .sfSpeech: "SFSpeech · \(language.englishName)"
        }
    }
}

/// Language policy captured at meeting start and passed to every subsystem
/// that can otherwise drift when Settings changes mid-call. Only an explicit
/// in-meeting switch (LiveSessionViewModel.switchLanguage) replaces it.
struct ResolvedMeetingLanguage: Codable, Equatable, Sendable {
    let selection: MeetingLanguageSelection
    let language: MeetingLanguageSelection
    let usedUnsupportedSystemFallback: Bool
    /// The language that was actually wanted when an Intel Mac forced English.
    /// Held separately from `selection`, which is "Mac language" for `.system`.
    var intelFallbackFrom: MeetingLanguageSelection?

    var usedIntelEnglishFallback: Bool { intelFallbackFrom != nil }
    var code: String { language.rawValue }
    var englishName: String { language.englishName }
    var isEnglish: Bool { language == .english }
    /// Multi-language mode: no single language to name in prompts or UI.
    var isAuto: Bool { language == .auto }
    /// For "Downloading … transcription" and engine errors.
    var transcriptionName: String { isAuto ? "multi-language" : englishName }
    var preferredEngine: TranscriptionEngine { isEnglish ? .parakeetV2 : .parakeetV3 }
    var shouldFoldVietnameseArtifacts: Bool { preferredEngine == .parakeetV2 }
    var sfSpeechLocaleIdentifier: String { "en-US" }
}

/// Which language AI notes are written in. "Same as the meeting" names the
/// language the meeting was held in (detected for multi-language calls);
/// "English" serves multilingual teams that keep notes in one language.
enum NotesLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case meeting
    case english

    static let defaultsKey = "notesLanguage"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .meeting: "Same as the meeting"
        case .english: "English"
        }
    }

    static var current: NotesLanguagePreference {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .meeting
    }

    /// The language name for the notes prompt, or nil to let the model
    /// follow the transcript's dominant language. `meetingLanguage` is the
    /// single language the call was held in, when there was one; `detected`
    /// is the dominant language heard (multi-language and switched calls).
    func notesLanguageName(meetingLanguage: MeetingLanguageSelection?,
                           detected: MeetingLanguageSelection?) -> String? {
        if self == .english { return MeetingLanguageSelection.english.englishName }
        if let meetingLanguage, meetingLanguage.isSpecific { return meetingLanguage.englishName }
        return detected?.englishName
    }
}
