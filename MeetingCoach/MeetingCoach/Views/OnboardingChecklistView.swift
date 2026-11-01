import SwiftUI

/// First-run empty state for the main pane: a live checklist that gets a
/// new person to their first coached meeting — permissions, the transcription
/// download (already running, with real progress), an optional source for AI
/// notes, then "join a meeting".
/// Replaces the old demo-centric card; the demo survives as a footer link.
struct OnboardingChecklistView: View {
    var liveSession: LiveSessionViewModel?
    var settings: SettingsViewModel?

    @Environment(\.openSettings) private var openSettings
    @State private var micState = PermissionStatus.microphone
    @State private var screenState = PermissionStatus.screenRecording
    // TCC has no change notifications — poll while visible so rows flip
    // moments after the user grants in the system dialog / System Settings.
    private let permissionPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @State private var claudeCodeInstalled = ClaudeAccount.executable != nil
    @State private var claudeConnected = false
    @State private var claudeTask: Task<Void, Never>?
    @State private var claudeBusy = false
    @State private var claudeError: String?

    private var download: ParakeetDownloadState { .shared }
    private var resolvedLanguage: ResolvedMeetingLanguage {
        settings?.resolvedMeetingLanguage ?? MeetingLanguageSelection.current.resolved()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 4) {
                Text("Get set up for your first meeting")
                    .font(Dorado.barlowXBold(22))
                    .foregroundStyle(Dorado.midnight)
                    .frame(maxWidth: .infinity)
                Text("Two permissions, one download — then it's automatic.")
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey500)
                    .frame(maxWidth: .infinity)
            }

            microphoneRow
            screenRecordingRow
            transcriptionRow
            aiNotesRow
            joinMeetingRow

            Divider()

            if let settings { advancedCoachingOption(settings) }

            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(settings?.usesCloudAI == true
                         ? "Audio is never stored and never leaves this Mac. Meeting text goes to \(settings?.aiConfiguration.provider.title ?? "your AI provider") for AI features."
                         : "Audio is never stored. Transcripts, models, coaching — everything stays on this Mac.")
                        .font(Dorado.roboto(12))
                        .foregroundStyle(Dorado.grey600)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(Dorado.dollar)
                }
                if let liveSession {
                    Button("Curious what a nudge looks like? Watch the 15-second demo") {
                        liveSession.startDemo()
                    }
                    .buttonStyle(.plain)
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.bolt)
                }
                Button("Coming from Granola? Import your meetings") {
                    openSettings()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
        .padding(28)
        .frame(maxWidth: 440)
        .background(RoundedRectangle(cornerRadius: 12).fill(Dorado.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Dorado.border, lineWidth: 1))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .onAppear(perform: refreshPermissions)
        .onReceive(permissionPoll) { _ in refreshPermissions() }
        .onDisappear { claudeTask?.cancel() }
    }

    private func refreshPermissions() {
        micState = PermissionStatus.microphone
        screenState = PermissionStatus.screenRecording
        // Polled here too, so Connect appears once someone finishes installing.
        claudeCodeInstalled = ClaudeAccount.executable != nil
    }

    // MARK: - Rows

    private var microphoneRow: some View {
        checklistRow(done: micState == .granted,
                     title: "Microphone access",
                     caption: micState == .denied
                         ? "Denied — enable MeetMouse in System Settings."
                         : "So the coach can hear your side of the call.") {
            if micState != .granted {
                Button(micState == .denied ? "Open Settings" : "Grant") {
                    PermissionStatus.requestMicrophone { refreshPermissions() }
                }
                .font(.caption)
            }
        } detail: {
            EmptyView()
        }
    }

    private var screenRecordingRow: some View {
        checklistRow(done: screenState == .granted,
                     title: "Screen Recording",
                     caption: "How macOS lets us hear the other side of the call. Nothing is recorded or stored.") {
            if screenState != .granted {
                Button("Grant") {
                    PermissionStatus.requestScreenRecording()
                }
                .font(.caption)
            }
        } detail: {
            EmptyView()
        }
    }

    private var transcriptionRow: some View {
        let engine = resolvedLanguage.preferredEngine
        // Intel: no download will ever run — show the row as settled with an
        // honest caption instead of an eternally-unchecked download.
        return checklistRow(done: download.isReady(for: engine)
                         || !PlatformSupport.neuralModelsSupported,
                     active: download.isActive(for: engine),
                     title: "Transcription engine",
                     caption: PlatformSupport.neuralModelsSupported
                         ? "\(engine == .parakeetV2 ? "Parakeet v2" : "Parakeet v3") for \(resolvedLanguage.englishName), on-device (~600 MB). Downloads automatically."
                         : "Intel Mac: uses Apple's built-in English transcription. The high-accuracy engine and speaker naming need Apple Silicon.") {
            EmptyView()
        } detail: {
            ParakeetProgressLine(engine: engine)
        }
    }

    @ViewBuilder private var aiNotesRow: some View {
        let isMissing = settings?.ollamaSelectedModelMissing == true
        let usesCloud = (settings?.usesCloudAI == true) && !isMissing
        let hasLocalModel = settings.map { !$0.availableModels.isEmpty } ?? false
        let downloading = settings?.downloadingModel != nil
        let caption: String = {
            if isMissing {
                return "Selected Ollama model is missing. Choose another model in Settings → AI."
            }
            if usesCloud {
                if settings?.aiConfiguration.provider == .ollama {
                    return settings?.aiConfiguration.isLoopbackOllama == true
                        ? "Ollama on this Mac writes your notes after each call."
                        : "Ollama at \(settings?.aiConfiguration.baseURL ?? "") writes your notes after each call."
                }
                return "\(settings?.aiConfiguration.provider.title ?? "Cloud AI") writes your notes after each call."
            }
            if hasLocalModel {
                return "A local model writes your notes on this Mac after each call."
            }
            if claudeCodeInstalled {
                return "Your Claude account is the lightest way to get them, and nothing slows your Mac during calls. Without AI you still get a basic recap."
            }
            return "A local model writes them on this Mac and only loads after a call, so calls stay fast. Without AI you still get a basic recap."
        }()
        checklistRow(done: usesCloud || hasLocalModel,
                     active: downloading || claudeBusy,
                     title: "AI notes after each call",
                     titleBadge: "optional",
                     caption: caption) {
            if let settings, downloading {
                Button("Cancel") { settings.cancelDownload() }
                    .font(.caption)
            } else if claudeBusy {
                Button("Cancel") { claudeTask?.cancel() }
                    .font(.caption)
            }
        }
 detail: {
            if let settings, !usesCloud, !hasLocalModel {
                if downloading {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: settings.downloadProgress)
                            .controlSize(.small)
                        Text(settings.downloadStatus)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else if autoPullPending(settings) {
                    Text("Queued — starts after the transcription engine.")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    notesSetupControls(settings)
                }
            }
        }
    }

    /// A switch, not a checklist row: most people should leave this off, so it
    /// must not read as an unfinished setup step.
    private func advancedCoachingOption(_ settings: SettingsViewModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Advanced live coaching").font(Dorado.barlowBold(15)).foregroundStyle(Dorado.midnight)
                Text("Off keeps your calls smooth. On adds AI nudges during calls. \(settings.liveCoachingCostNote)")
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey600)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("Advanced live coaching", isOn: Binding(
                get: { settings.semanticCoachEnabled },
                set: { enabled in
                    settings.semanticCoachEnabled = enabled
                    if !enabled { liveSession?.shedSessionModel(settings: nil) }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
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

    @ViewBuilder private func notesSetupControls(_ settings: SettingsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if claudeConnected {
                Text(settings.semanticCoachEnabled
                     ? "Signed in. Turning this on sends meeting text, never audio, to Claude for notes and questions, and throughout each call for advanced live coaching, which uses your plan allowance."
                     : "Signed in. Turning this on sends meeting text, never audio, to Claude for notes and questions.")
                    .font(.caption).foregroundStyle(Dorado.grey600)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn on Claude notes") { enableClaude(settings) }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .disabled(claudeBusy)
            } else if claudeCodeInstalled {
                HStack(spacing: 8) {
                    Button("Connect Claude") { connectClaude() }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .disabled(claudeBusy)
                    Button("Download local model (\(recommendedCatalogModel.diskSize))") {
                        settings.downloadModel(recommendedCatalogModel)
                    }
                    .font(.caption)
                    .disabled(claudeBusy)
                }
            } else {
                Button("Download local model (\(recommendedCatalogModel.diskSize))") {
                    settings.downloadModel(recommendedCatalogModel)
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                Link("Have Claude? Set up Claude Code ↗", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                    .font(.caption)
            }
            if let error = claudeError ?? settings.downloadError {
                Text(error)
                    .font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    /// Skips the browser when Claude Code is already signed in. Connecting sends
    /// no meeting text: that takes the separate Turn on step.
    private func connectClaude() {
        claudeBusy = true
        claudeError = nil
        claudeTask = Task {
            defer { claudeBusy = false }
            do {
                do { try await ClaudeAccount.checkConnection() }
                catch is CancellationError { return }
                catch { try await ClaudeAccount.login() }
                try Task.checkCancellation()
                claudeConnected = true
            } catch is CancellationError {
            } catch {
                claudeError = error.localizedDescription
            }
        }
    }

    private func enableClaude(_ settings: SettingsViewModel) {
        guard let model = AIProvider.claudeAccount.models.first else { return }
        do {
            try settings.enableCloudAI(.init(provider: .claudeAccount, model: model), key: "")
            claudeError = nil
        } catch {
            claudeError = error.localizedDescription
        }
    }

    private var joinMeetingRow: some View {
        checklistRow(done: false,
                     active: liveSession?.isLive == true,
                     title: liveSession?.isLive == true ? "You're live!" : "Join a meeting",
                     caption: "We detect Zoom & Meet and offer to start — or click Go Live any time.") {
            EmptyView()
        } detail: {
            EmptyView()
        }
    }

    // MARK: - Row scaffolding

    private func checklistRow(done: Bool, active: Bool = false,
                              title: String, titleBadge: String? = nil,
                              caption: String,
                              @ViewBuilder trailing: () -> some View,
                              @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Dorado.dollar)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Color(hex: 0xC7CED7))
                }
            }
            .font(.system(size: 18))
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(Dorado.barlowBold(15)).foregroundStyle(Dorado.midnight)
                    if let titleBadge {
                        Text(titleBadge)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Dorado.surfaceSubtle)
                            .foregroundStyle(Dorado.grey600)
                            .clipShape(Capsule())
                    }
                }
                Text(caption)
                    .font(Dorado.roboto(13))
                    .foregroundStyle(Dorado.grey600)
                    .fixedSize(horizontal: false, vertical: true)
                detail()
            }

            Spacer(minLength: 0)
            trailing()
        }
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
