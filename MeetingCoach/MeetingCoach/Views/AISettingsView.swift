import SwiftUI

struct AISettingsView: View {
    @Bindable var settings: SettingsViewModel
    let liveSession: LiveSessionViewModel
    /// Provider shown in the "Use an API key instead" group (never local / account).
    @State private var keyProvider: AIProvider = .anthropic
    @State private var keyModel = ""
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var consent = false
    @State private var showKeys = false
    @State private var busy = false
    @State private var accountConnected = false
    @State private var accountTask: Task<Void, Never>?
    @State private var status: String?
    @State private var isError = false

    private var active: AIProvider { settings.aiConfiguration.provider }
    private var localReady: Bool { !settings.availableModels.isEmpty }
    private var downloading: Bool { settings.downloadingModel != nil }

    var body: some View {
        Form {
            Section("AI for meeting notes") {
                Text("Writes your notes after each call and answers questions about your meetings.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.usesCloudAI {
                    activeRow
                } else {
                    claudeChoice
                    localChoice
                }
                if let status {
                    Text(status).font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                }
                keyGroup
            }
            Section("During meetings") {
                Toggle("Advanced live coaching", isOn: $settings.semanticCoachEnabled)
                Text("Adds AI nudges during calls. \(settings.liveCoachingCostNote)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("About data") {
                    Text("Audio and transcription stay on your Mac. Provider changes apply to the next request, and switching away from a cloud provider stops future requests to it. Requests already sent cannot be recalled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadKeyProvider(); silentAccountCheck() }
        .task { await settings.refreshModels() }
        .onChange(of: settings.semanticCoachEnabled) { _, enabled in
            if !enabled { liveSession.shedSessionModel(settings: nil) }
        }
        .onChange(of: keyProvider) { _, _ in loadKeyProvider() }
        .onChange(of: key) { _, _ in status = nil }
        .onDisappear { accountTask?.cancel() }
    }

    // MARK: Active cloud

    private var activeRow: some View {
        HStack {
            Label(active.title, systemImage: "checkmark.circle.fill")
                .fixedSize()
            Picker("Model", selection: Binding(
                get: { settings.aiConfiguration.model },
                set: { changeActiveModel($0) })) {
                ForEach(active.models, id: \.self) { Text(AIProvider.modelTitle($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            Spacer()
            Button("Switch to local") {
                settings.useLocalAI()
                isError = false
                status = localReady ? "Local AI on. Future cloud requests are stopped."
                                    : "Local AI on, download a model to get notes."
                silentAccountCheck()
            }
        }
    }

    // MARK: Choices when nothing cloud is active

    private var claudeChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude account").font(.headline)
            Text("Use your Claude plan.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Sends meeting text, names and notes (never audio) to Claude. Uses your Claude plan’s limits.")
                .font(.caption).foregroundStyle(.secondary)
            if settings.semanticCoachEnabled {
                Text("Live coaching also sends text during the call.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if accountConnected {
                HStack {
                    Button("Turn on Claude notes") { enableAccount() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    if busy { Button("Cancel") { accountTask?.cancel() } }
                }
            } else if ClaudeAccount.executable == nil {
                // In-app Claude Code install (#74) lives in the shared setup sheet.
                HStack {
                    SetUpAINotesButton(settings: settings, onReady: setupFinished)
                    Link("Install it yourself ↗", destination: ClaudeAccount.installDocsURL).font(.caption)
                }
            } else {
                HStack {
                    Button("Connect Claude") { connectAccount() }
                        .disabled(busy)
                    if busy { Button("Cancel") { accountTask?.cancel() } }
                    // Outdated or broken Claude Code: the setup sheet can repair it.
                    if isError, let status, ClaudeAccount.isSetupProblem(status) {
                        SetUpAINotesButton(settings: settings, onReady: setupFinished)
                    }
                }
            }
        }
    }

    private var localChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Local, free and open source").font(.headline)
                if !settings.usesCloudAI && localReady {
                    Text("Current choice").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Runs on this Mac, works offline. Nothing leaves your Mac.")
                .font(.caption).foregroundStyle(.secondary)
            if downloading {
                ProgressView(value: settings.downloadProgress).controlSize(.small)
                HStack {
                    Text(settings.downloadStatus).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { settings.cancelDownload() }
                }
            } else if localReady {
                Label("Ready", systemImage: "checkmark").font(.callout)
            } else {
                Button("Download (\(recommendedCatalogModel.diskSize))") {
                    settings.downloadModel(recommendedCatalogModel)
                }
            }
            if let error = settings.downloadError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    // MARK: API keys

    private var keyGroup: some View {
        DisclosureGroup("Use an API key instead", isExpanded: $showKeys) {
            Picker("Provider", selection: $keyProvider) {
                ForEach([AIProvider.anthropic, .openai]) { Text($0.title).tag($0) }
            }
            .disabled(busy)
            if active != keyProvider {
                Picker("Model", selection: $keyModel) {
                    ForEach(keyProvider.models, id: \.self) { Text(AIProvider.modelTitle($0)).tag($0) }
                }
                .disabled(busy)
            }
            SecureField(hasSavedKey ? "Saved key — enter to replace" : "Paste API key", text: $key)
                .disabled(busy)
                .textContentType(.password)
            Link("Get an API key ↗", destination: keyProvider.keyURL)
            Text("Stored in this Mac’s Keychain. Billed by your provider, separately from any subscription.")
                .font(.caption).foregroundStyle(.secondary)
            Text(settings.cloudConsentText(providerTitle: keyProvider.title))
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Allow AI features to send this text to \(keyProvider.title)", isOn: $consent)
                .disabled(busy)
            HStack {
                Button(busy ? "Checking…" : "Save and enable") { saveKey() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !consent || (key.isEmpty && !hasSavedKey))
                if busy { Button("Cancel") { accountTask?.cancel() } }
                if hasSavedKey {
                    Button("Remove saved key", role: .destructive) { removeKey() }
                        .disabled(busy)
                }
            }
            Text("Save first sends a short sample prompt to check the key, which may cost a fraction of a cent.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func loadKeyProvider() {
        if active.requiresAPIKey { keyProvider = active }
        key = ""; consent = false; status = nil; isError = false
        keyModel = active == keyProvider ? settings.aiConfiguration.model : (keyProvider.models.first ?? "")
        if !keyProvider.models.contains(keyModel) { keyModel = keyProvider.models.first ?? "" }
        do { hasSavedKey = try AIKeychain.read(keyProvider) != nil }
        catch { hasSavedKey = false; fail(error) }
    }
    private func fail(_ error: Error) { status = error.localizedDescription; isError = true }

    /// After the shared setup sheet finishes (it enables AI itself).
    private func setupFinished() {
        isError = false; status = nil
        silentAccountCheck()
    }

    /// Detects an existing sign-in without a browser; sends no meeting text.
    private func silentAccountCheck() {
        guard ClaudeAccount.executable != nil, !settings.usesCloudAI, !accountConnected else { return }
        accountTask?.cancel()
        accountTask = Task {
            if (try? await ClaudeAccount.checkConnection()) != nil, !Task.isCancelled { accountConnected = true }
        }
    }

    /// Skips the browser when already signed in. Connecting sends no meeting
    /// text: that takes the separate "Turn on Claude notes" step.
    private func connectAccount() {
        accountTask?.cancel()
        busy = true; isError = false; status = nil
        accountTask = Task {
            defer { busy = false }
            do {
                do { try await ClaudeAccount.checkConnection() }
                catch is CancellationError { throw CancellationError() }
                catch {
                    status = "Complete sign-in in your browser. Waiting for Claude…"
                    try await ClaudeAccount.login()
                }
                try Task.checkCancellation()
                accountConnected = true; status = nil
            } catch is CancellationError { status = "Sign-in cancelled."
            } catch { accountConnected = false; fail(error) }
        }
    }

    /// The button is the consent: its sentence says text goes to Claude.
    private func enableAccount() {
        guard let model = AIProvider.claudeAccount.models.first else { return }
        busy = true
        accountTask = Task {
            defer { busy = false }
            do {
                try await ClaudeAccount.checkConnection()
                try Task.checkCancellation()
                try settings.enableCloudAI(.init(provider: .claudeAccount, model: model), key: "")
                isError = false
                status = settings.semanticCoachEnabled ? "Claude account enabled for coaching, reviews and chat." : "Claude account enabled for reviews and chat."
            } catch is CancellationError { status = "Cancelled."
            } catch { fail(error) }
        }
    }

    private func changeActiveModel(_ model: String) {
        do { try settings.enableCloudAI(.init(provider: active, model: model), key: ""); status = nil }
        catch { fail(error) }
    }

    private func saveKey() {
        let configuration = AIConfiguration(provider: keyProvider, model: keyModel)
        do {
            let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.contains(where: { $0.isWhitespace || $0.isNewline }) {
                status = "That key contains spaces or line breaks. Paste just the key."; isError = true; return
            }
            let testKey = candidate.isEmpty ? (try AIKeychain.read(keyProvider) ?? "") : candidate
            guard !testKey.isEmpty else { status = "Enter an API key first."; isError = true; return }
            accountTask?.cancel()
            busy = true; status = nil
            accountTask = Task {
                defer { busy = false }
                do {
                    _ = try await CloudAI.complete(configuration: configuration, key: testKey,
                                                    system: "Reply briefly.", user: "Say OK.", maxTokens: 32)
                    try Task.checkCancellation()
                    try settings.enableCloudAI(configuration, key: candidate)
                    key = ""; hasSavedKey = true; isError = false
                    status = "\(keyProvider.title) enabled."
                } catch is CancellationError { status = "Cancelled."
                } catch { fail(error) }
            }
        } catch { fail(error) }
    }

    private func removeKey() {
        do {
            // Disable first: even a Keychain failure must not leave cloud enabled.
            if active == keyProvider { settings.useLocalAI() }
            try AIKeychain.delete(keyProvider)
            key = ""; hasSavedKey = false; consent = false; isError = false
            status = "Key removed."
        } catch { fail(error) }
    }
}
