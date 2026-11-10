import SwiftUI

/// First-run empty state for the main pane: three short rows (microphone,
/// call audio, AI notes) that get a new person to their first coached meeting.
/// The speech-model download runs on its own and only surfaces as one slim
/// status line while it downloads or after it fails. The demo and Granola
/// import survive as quiet footer links.
struct OnboardingChecklistView: View {
    var liveSession: LiveSessionViewModel?
    var settings: SettingsViewModel?

    @Environment(\.openSettings) private var openSettings
    @State private var micState = PermissionStatus.microphone
    @State private var screenState = PermissionStatus.screenRecording
    // TCC has no change notifications — poll while visible so rows flip
    // moments after the user grants in the system dialog / System Settings.
    private let permissionPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var download: ParakeetDownloadState { .shared }
    private var resolvedLanguage: ResolvedMeetingLanguage {
        settings?.resolvedMeetingLanguage ?? MeetingLanguageSelection.current.resolved()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 4) {
                Text("Get set up")
                    .font(Dorado.barlowXBold(22))
                    .foregroundStyle(Dorado.midnight)
                    .frame(maxWidth: .infinity)
                Text("Three quick steps. Then it runs on its own.")
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey500)
                    .frame(maxWidth: .infinity)
            }

            microphoneRow
            callAudioRow
            aiNotesRow
            speechModelStatus

            Divider()

            footer
        }
        .padding(24)
        .frame(maxWidth: 500)
        .background(RoundedRectangle(cornerRadius: 12).fill(Dorado.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Dorado.border, lineWidth: 1))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .onAppear(perform: refreshPermissions)
        .onReceive(permissionPoll) { _ in refreshPermissions() }
    }

    private func refreshPermissions() {
        micState = PermissionStatus.microphone
        screenState = PermissionStatus.screenRecording
    }

    // MARK: - Rows

    private var microphoneRow: some View {
        checklistRow(done: micState == .granted,
                     title: "Microphone",
                     caption: micState == .denied
                         ? "Turn it on in System Settings."
                         : "Hears your side of the call.") {
            if micState != .granted {
                Button(micState == .denied ? "Open Settings" : "Allow") {
                    PermissionStatus.requestMicrophone { refreshPermissions() }
                }
                .font(.caption)
                .accessibilityLabel(micState == .denied ? "Open System Settings for the microphone" : "Allow microphone access")
            }
        } detail: {
            EmptyView()
        }
    }

    private var callAudioRow: some View {
        checklistRow(done: screenState == .granted,
                     title: "Call audio",
                     caption: "Hears the other side. Nothing is recorded.") {
            if screenState != .granted {
                Button("Allow") {
                    PermissionStatus.requestScreenRecording()
                }
                .font(.caption)
                .help("macOS asks for this as Screen Recording. MeetMouse only uses it to hear call audio.")
                .accessibilityLabel("Allow call audio. macOS asks for this as Screen Recording.")
            }
        } detail: {
            EmptyView()
        }
    }

    @ViewBuilder private var aiNotesRow: some View {
        let ready = settings?.aiReady == true
        checklistRow(done: ready,
                     title: "AI notes",
                     caption: "Summary and follow-ups after each call.") {
            EmptyView()
        } detail: {
            if let settings, !ready || settings.downloadingModel != nil {
                AISetupView(settings: settings,
                            localQueued: autoPullPending(settings) && settings.downloadingModel == nil)
                    .padding(.top, 6)
            }
        }
    }

    /// One slim line, only while the speech model downloads or after it failed.
    /// Nothing once it is done (or on Intel Macs, where no download runs).
    @ViewBuilder private var speechModelStatus: some View {
        let engine = resolvedLanguage.preferredEngine
        if PlatformSupport.neuralModelsSupported {
            if download.isPending(for: engine) {
                statusLine { Text("Speech model queued…") }
            } else if download.activeEngine == engine {
                switch download.phase {
                case .downloading(let fraction, _):
                    statusLine { Text("Downloading speech model… \(Int(fraction * 100))%") }
                case .compiling:
                    statusLine { Text("Preparing speech model…") }
                case .idle, .ready, .failed:
                    EmptyView()
                }
            } else if download.failureMessage(for: engine) != nil {
                statusLine {
                    HStack(spacing: 6) {
                        Text("Speech model download failed.").foregroundStyle(.red)
                        Button("Retry") { download.retry(for: engine) }
                    }
                }
            }
        }
    }

    private func statusLine<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.caption)
            .foregroundStyle(Dorado.grey600)
            .padding(.leading, 34)
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { privacyLine; Spacer(minLength: 8); footerLinks }
            VStack(alignment: .leading, spacing: 6) { privacyLine; footerLinks }
        }
    }

    private var privacyLine: some View {
        Label {
            Text("Audio never leaves this Mac.")
                .font(Dorado.roboto(12))
                .foregroundStyle(Dorado.grey600)
        } icon: {
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundStyle(Dorado.dollar)
        }
        .fixedSize()
    }

    private var footerLinks: some View {
        HStack(spacing: 6) {
            if let liveSession {
                Button("Watch the demo") { liveSession.startDemo() }
                    .buttonStyle(.plain)
                Text("·").foregroundStyle(Dorado.grey500)
            }
            Button("Import from Granola") { openSettings() }
                .buttonStyle(.plain)
        }
        .font(Dorado.roboto(12))
        .foregroundStyle(Dorado.bolt)
        .fixedSize()
    }

    /// True only while the one-time pull is really waiting on transcription. The
    /// pull can also skip itself (low disk, no engine) without setting its flag,
    /// and those people still need the setup controls.
    private func autoPullPending(_ settings: SettingsViewModel) -> Bool {
        let engine = resolvedLanguage.preferredEngine
        return settings.semanticCoachEnabled
            && !UserDefaults.standard.bool(forKey: SettingsViewModel.autoModelPullAttemptedKey)
            && (download.isActive(for: engine) || download.isPending(for: engine))
    }

    // MARK: - Row scaffolding

    /// Done rows collapse to the title with a green check.
    private func checklistRow(done: Bool, title: String, caption: String,
                              @ViewBuilder trailing: () -> some View,
                              @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Dorado.dollar)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Color(hex: 0xC7CED7))
                }
            }
            .font(.system(size: 18))
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Dorado.barlowBold(15)).foregroundStyle(Dorado.midnight)
                if !done {
                    Text(caption)
                        .font(Dorado.roboto(13))
                        .foregroundStyle(Dorado.grey600)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detail()
            }

            Spacer(minLength: 0)
            trailing()
        }
        .accessibilityElement(children: .contain)
    }
}

/// Compact live status for the Parakeet download, shared by the onboarding
/// checklist and the reduced-accuracy session banners. Renders nothing when
/// there is nothing to say (idle or already downloaded).
struct ParakeetProgressLine: View {
    let engine: TranscriptionEngine
    private var download: ParakeetDownloadState { .shared }

    init(engine: TranscriptionEngine = MeetingLanguageSelection.current.resolved().preferredEngine) {
        self.engine = engine
    }

    @ViewBuilder
    var body: some View {
        if download.isPending(for: engine) {
            Text("Queued — another transcription engine is downloading first.")
                .font(.caption2).foregroundStyle(.tertiary)
        } else if download.activeEngine == engine {
            switch download.phase {
            case .downloading(let fraction, let detail):
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                    Text("\(Int(fraction * 100))%\(detail.isEmpty ? "" : " · \(detail)")")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            case .compiling:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Optimizing for this Mac…")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            case .idle, .ready, .failed:
                EmptyView()
            }
        } else if let message = download.failureMessage(for: engine) {
            HStack(spacing: 6) {
                Text("Download failed: \(message)")
                    .font(.caption2).foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") { download.retry(for: engine) }
                    .font(.caption2)
            }
        } else {
            EmptyView()
        }
    }
}
