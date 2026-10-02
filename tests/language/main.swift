import Foundation

var failed = false
func check(_ condition: Bool, _ label: String) {
    print("language \(label): \(condition ? "PASS" : "FAIL")")
    if !condition { failed = true }
}

let supportedCodes: Set<String> = [
    "en", "bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de", "el",
    "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl",
    "es", "sv", "uk",
]
let explicit = MeetingLanguageSelection.specificLanguages
check(explicit.count == 25, "exposes 25 explicit languages")
check(Set(MeetingLanguageSelection.allCases) == Set(explicit + [.system, .auto]),
      "policies are exactly Mac language and Auto-detect")
check(Set(explicit.map(\.rawValue)) == supportedCodes, "ISO mapping is exact")
check(explicit.allSatisfy { !$0.englishName.isEmpty && !$0.pickerName.isEmpty },
      "every language has picker copy")
// Engine routing is asserted on the Apple Silicon path explicitly, so the
// result doesn't depend on which machine runs the gate.
check(explicit.allSatisfy {
    $0.resolved(neuralModelsSupported: true).preferredEngine
        == ($0 == .english ? .parakeetV2 : .parakeetV3)
}, "all 25 languages route to the required engine")

let english = MeetingLanguageSelection.english.resolved(localeIdentifier: "es_ES")
check(english.code == "en" && english.preferredEngine == .parakeetV2,
      "explicit English routes to v2 regardless of Mac")

let spanishMac = MeetingLanguageSelection.system.resolved(
    localeIdentifier: "es_ES", neuralModelsSupported: true)
check(spanishMac.code == "es" && spanishMac.preferredEngine == .parakeetV3,
      "Mac Spanish resolves to v3")
check(spanishMac.selection == .system && !spanishMac.usedUnsupportedSystemFallback,
      "Mac-language provenance retained")

let unsupportedMac = MeetingLanguageSelection.system.resolved(localeIdentifier: "ja_JP")
check(unsupportedMac.code == "en" && unsupportedMac.usedUnsupportedSystemFallback,
      "unsupported Mac language explains English fallback")

// Intel can't run Parakeet at all, so every selection resolves to English
// rather than refusing to start the meeting. The wanted language is retained
// for the Settings explanation, and English is never marked as a fallback.
let intelSpanish = MeetingLanguageSelection.spanish.resolved(
    localeIdentifier: "en_US", neuralModelsSupported: false)
check(intelSpanish.code == "en" && intelSpanish.preferredEngine == .parakeetV2,
      "Intel forces an explicit non-English selection to English")
check(intelSpanish.intelFallbackFrom == .spanish && intelSpanish.usedIntelEnglishFallback,
      "Intel fallback names the language that was wanted")
check(!intelSpanish.usedUnsupportedSystemFallback,
      "Intel fallback is not confused with an unsupported Mac language")

let intelFrenchMac = MeetingLanguageSelection.system.resolved(
    localeIdentifier: "fr_FR", neuralModelsSupported: false)
check(intelFrenchMac.code == "en" && intelFrenchMac.intelFallbackFrom == .french,
      "Intel Mac-language French resolves to English, not a refused session")

let intelEnglish = MeetingLanguageSelection.system.resolved(
    localeIdentifier: "en_US", neuralModelsSupported: false)
check(intelEnglish.code == "en" && !intelEnglish.usedIntelEnglishFallback,
      "Intel English needs no fallback explanation")

let siliconFrench = MeetingLanguageSelection.system.resolved(
    localeIdentifier: "fr_FR", neuralModelsSupported: true)
check(siliconFrench.code == "fr" && !siliconFrench.usedIntelEnglishFallback,
      "Apple Silicon keeps the selected language")

let persisted = MeetingLanguageSelection.resolvedPersistedCode("uk")
check(persisted?.language == .ukrainian && persisted?.englishName == "Ukrainian",
      "saved ISO language restores review policy")
check(MeetingLanguageSelection.resolvedPersistedCode("ja") == nil,
      "unsupported saved ISO stays legacy/dominant-language mode")

// Auto-detect: Parakeet v3 with no script hint, never English-only coaching.
let auto = MeetingLanguageSelection.auto.resolved(localeIdentifier: "en_US",
                                                  neuralModelsSupported: true)
check(auto.isAuto && auto.code == "auto" && !auto.isEnglish
      && auto.preferredEngine == .parakeetV3 && !auto.shouldFoldVietnameseArtifacts,
      "Auto-detect routes to v3 as a non-English session")
check(auto.transcriptionName == "multi-language" && MeetingLanguageSelection.auto.quickName == "Auto-detect",
      "Auto-detect has readable status copy")
let intelAuto = MeetingLanguageSelection.auto.resolved(localeIdentifier: "en_US",
                                                       neuralModelsSupported: false)
check(intelAuto.code == "en" && intelAuto.intelFallbackFrom == .auto,
      "Intel Auto-detect resolves to English and says why")
check(MeetingLanguageSelection.resolvedPersistedCode("auto") == nil,
      "saved auto sessions re-detect their notes language")

// Recent languages: newest first, deduplicated, three max, policies skipped.
let recentDefaults = UserDefaults(suiteName: "language-check-recents")!
recentDefaults.removePersistentDomain(forName: "language-check-recents")
for language in [MeetingLanguageSelection.english, .polish, .auto, .system, .german, .polish, .french] {
    MeetingLanguageSelection.noteUsed(language, defaults: recentDefaults)
}
check(MeetingLanguageSelection.recent(recentDefaults) == [.french, .polish, .german],
      "recent languages keep the last three distinct picks")
recentDefaults.removePersistentDomain(forName: "language-check-recents")

// Notes language: the meeting's own language, the detected main language
// for multi-language meetings, or always English.
check(NotesLanguagePreference.meeting.notesLanguageName(meetingLanguage: .spanish, detected: .english) == "Spanish",
      "notes follow a single-language meeting")
check(NotesLanguagePreference.meeting.notesLanguageName(meetingLanguage: nil, detected: .polish) == "Polish",
      "multi-language notes follow the detected main language")
check(NotesLanguagePreference.meeting.notesLanguageName(meetingLanguage: .auto, detected: nil) == nil,
      "undetectable notes fall back to the dominant-language prompt")
check(NotesLanguagePreference.english.notesLanguageName(meetingLanguage: .polish, detected: .polish) == "English",
      "English notes preference overrides the meeting language")
check(NotesLanguagePreference.current == .meeting, "notes default to the meeting language")

// On-device detection (NLLanguageRecognizer) on meeting-style lines.
let lines: [(MeetingLanguageSelection, String)] = [
    (.english, "Sounds good, I can send the updated timeline to everyone by Friday."),
    (.polish, "Dobra, to w takim razie przesuwamy launch na przyszły tydzień?"),
    (.german, "Ja, das klingt gut, ich schicke dir morgen die Unterlagen."),
    (.czech, "Dobře, tak to posuneme na příští týden a uvidíme."),
    (.slovak, "Dobre, tak to posunieme na budúci týždeň a uvidíme."),
    (.ukrainian, "Добре, тоді перенесемо це на наступний тиждень."),
    (.russian, "Хорошо, тогда перенесём это на следующую неделю."),
    (.portuguese, "Tudo bem, então vamos mudar para a próxima semana."),
    (.spanish, "Vale, entonces lo movemos a la semana que viene."),
]
check(lines.allSatisfy { TranscriptLanguageDetector.language(of: $0.1) == $0.0 },
      "detector names meeting sentences across scripts and close pairs")
check(TranscriptLanguageDetector.language(of: "OK.") == nil
      && TranscriptLanguageDetector.language(of: "123 — 456") == nil,
      "detector declines one-word and letterless lines")

var tally = TranscriptLanguageDetector.Tally()
tally.add(lines[1].1)
tally.add("Tak, ale najpierw muszę to potwierdzić z zespołem w Berlinie.")
check(!tally.isMultilingual && tally.dominant == .polish, "one-language tally is not multilingual")
tally.add(lines[0].1)
check(tally.isMultilingual && tally.spoken == [.polish, .english],
      "a real second language makes the tally multilingual, most-spoken first")
var stray = TranscriptLanguageDetector.tally(Array(repeating: lines[1].1, count: 8))
stray.add("Sounds good.")
check(!stray.isMultilingual, "a stray line in another language stays below the 15% share")

UserDefaults.standard.set("fr", forKey: MeetingLanguageSelection.defaultsKey)
check(MeetingLanguageSelection.current == .french, "stored global selection loads")
UserDefaults.standard.removeObject(forKey: MeetingLanguageSelection.defaultsKey)
check(MeetingLanguageSelection.current == .system, "unset selection defaults to Mac language")

exit(failed ? 1 : 0)
