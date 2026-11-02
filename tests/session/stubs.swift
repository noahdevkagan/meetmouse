import Foundation

final class BlockNetworkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String] = []

    static var unexpectedRequests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request.url?.absoluteString ?? "<no URL>")
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

func mclog(_ message: String) {}

struct SignalExample: Codable, Sendable {
    let signalId: String
    let evidence: String
    let nudge: String
}

enum TrainingStore {
    static func examplesByType() -> [String: [SignalExample]] { [:] }
    static func emphasizedTypes() -> Set<NudgeType> { [] }
    static let sensitivityBoost = 0.9
}

// Headless stand-ins for the heavy leaves LiveSessionViewModel touches.
// Everything else in the harness is the app's REAL code. These stubs avoid
// hardware, dependencies, and reads or writes to the app's shared data.
// Keep each surface to exactly what the view model calls.

/// One finalized "who spoke when" span (real one lives in SpeakerDiarizer,
/// which imports FluidAudio).
struct SpeakerSegment: Sendable {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
}

/// Which audio source a diarization result describes (real one lives in
/// AudioCaptureManager).
enum DiarizationChannel: String, Sendable {
    case mic
    case system
}

/// Capture stub: exposes the same callback surface, records lifecycle
/// calls, never touches audio hardware. Tests drive the VM through these
/// hooks — the same path live capture uses.
@MainActor
final class AudioCaptureManager {
    /// The most recently constructed instance — startLive() news one up
    /// internally, so tests reach the wired instance through here.
    static var last: AudioCaptureManager?

    var contextualHints: [String] = []
    var expectedParticipants: [String] = []
    var vocabulary: VocabularyNormalizer?
    var isMicOnly = false
    var isAppleCall = false
    private(set) var stopped = false
    /// Mirrors the real manager's engine attribution (recorded into saved
    /// sessions); tests can override to assert the header line.
    var engineLabel = "stub"
    var transcriptionEngine: TranscriptionEngine = .parakeetV2
    private(set) var language: ResolvedMeetingLanguage
    private(set) var startTime = Date()

    var onUtterance: ((Utterance) -> Void)?
    var onPartialText: ((String, String) -> Void)?
    var onSpeakerSegments: ((DiarizationChannel, [SpeakerSegment]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onSystemAudioLost: (() -> Void)?
    var onSystemAudioRestored: (() -> Void)?
    var onMicWarning: ((MicWarning?) -> Void)?
    var onOutputRoute: ((Bool) -> Void)?
    /// Recorded renames (label, name) — the real manager routes these to
    /// the channel diarizers and the voice-profile store.
    private(set) var renames: [(String, String)] = []

    init(language: ResolvedMeetingLanguage) {
        self.language = language
        Self.last = self
    }
    func start() async throws { startTime = Date() }
    func stop() { stopped = true }

    enum LanguageSwitchPhase: Sendable { case downloading, loading }
    /// Phases a switch reports before finishing, and an optional failure.
    var switchPhases: [LanguageSwitchPhase] = []
    var switchError: Error?
    private(set) var languageSwitches: [String] = []
    @discardableResult
    func switchLanguage(to target: ResolvedMeetingLanguage,
                        onPhase: @escaping @Sendable @MainActor (LanguageSwitchPhase) -> Void)
        async throws -> TranscriptionEngine {
        for phase in switchPhases { onPhase(phase) }
        if let switchError { throw switchError }
        language = target
        transcriptionEngine = target.preferredEngine
        languageSwitches.append(target.code)
        return target.preferredEngine
    }
    func renameSpeaker(_ label: String, to name: String) { renames.append((label, name)) }
}

/// Minimal rubric: stock tuning, no custom signals.
struct Rubric {
    var builtins: RubricTuning = [:]
    var customSemanticSignals: [CustomSemanticSignal] = []
    static let builtInDefault = Rubric()
}

@MainActor
final class SettingsViewModel {
    var usesCloudAI = false
    var selectedModel = "stub-model"
    var effectiveModelOverride: String?
    var effectiveModel: String { effectiveModelOverride ?? selectedModel }
    var deletingModel: String?
    var semanticCoachEnabled = false
    var useMock = true
    var defaultMeetingMinutes = 0
    var hasCheckedModels = false
    var ollamaReachable = false
    var availableModels: [OllamaModel] = []
    var meetingLanguage: MeetingLanguageSelection = .english
    var notesLanguage: NotesLanguagePreference = .meeting
    func loadRubricOrDefault() throws -> Rubric { Rubric() }
    func prepareAI(ollamaManager: OllamaManager) async -> Bool {
        if usesCloudAI { return true }
        guard await ollamaManager.ensureRunning() else { return false }
        await refreshModels()
        return !availableModels.isEmpty
    }

    // Test hooks. The real path reads this machine's free memory and talks to
    // an engine; these let a test choose the outcome and then assert what the
    // view model DID about it.
    /// Ordered record of the lifecycle's steps, so tests can assert sequence
    /// (refresh before resolve, preload before any pin) rather than only the
    /// final stored value.
    private(set) var callLog: [String] = []
    /// Blocks inside refreshModels until released — lets a test land Stop
    /// exactly during the refresh await.
    var refreshGate: (stream: AsyncStream<Void>, cont: AsyncStream<Void>.Continuation)?

    func refreshModels() async {
        callLog.append("refresh")
        if let gate = refreshGate {
            var it = gate.stream.makeAsyncIterator()
            _ = await it.next()
        }
    }
}

@MainActor
final class OllamaManager {
    enum Status: Equatable { case stopped, running, error(String) }
    var status: Status = .stopped
    /// false simulates an engine that won't come up — one of the ways
    /// activation must settle deterministic.
    var engineAvailable = true
    func start() { status = .running }
    func ensureRunning() async -> Bool { engineAvailable }
}
