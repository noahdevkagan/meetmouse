import SwiftUI

struct AISettingsView: View {
    @Bindable var settings: SettingsViewModel
    let liveSession: LiveSessionViewModel
    @State private var provider: AIProvider = .local
    @State private var model = ""
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var consent = false
    @State private var testing = false
    @State private var accountConnected = false
    @State private var accountTask: Task<Void, Never>?
    @State private var status: String?
    @State private var isError = false

    var body: some View {
        Form {
            Section("AI provider") {
                Label(settings.usesCloudAI ? "Active: \(settings.aiConfiguration.provider.title)" : "Active: Local (on this Mac)",
                      systemImage: settings.usesCloudAI ? "cloud" : "desktopcomputer")
                    .font(.headline)
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                .disabled(testing)

                if provider == .local {
                    Text("Local AI works offline after model downloads. Meeting text stays on your Mac. Manage local models in the main window’s coaching settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.usesCloudAI {
                        Button("Use local AI") {
                            settings.useLocalAI()
                            status = "Local AI enabled. Future cloud requests are stopped."
                            isError = false
                        }
                    }
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(provider.models, id: \.self) { Text(AIProvider.modelTitle($0)).tag($0) }
                    }
                    .disabled(testing)
                    if provider == .claudeAccount {
                        Label(accountConnected ? "Claude account connected" : "Connect your Claude subscription",
                              systemImage: accountConnected ? "checkmark.circle" : "person.crop.circle")
                        HStack {
                            Button("Connect Claude account") { connectAccount(login: true) }
                                .disabled(testing)
                            Button("Check sign-in") { connectAccount(login: false) }
                                .disabled(testing)
                            if testing {
                                Button("Cancel") { accountTask?.cancel() }
                            }
                        }
                        if ClaudeAccount.executable == nil {
                            Link("Install Claude Code ↗", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                        }
                        Text("Uses Claude Code 2.1.280 or later and its official sign-in. Your Claude plan’s usage limits and any enabled extra usage apply. Live coaching uses your allowance throughout a meeting. MeetMouse does not store your Claude login.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        SecureField(hasSavedKey ? "Saved key — enter to replace" : "Paste API key", text: $key)
                            .disabled(testing)
                            .textContentType(.password)
                        Link("Get an API key ↗", destination: provider.keyURL)
                        Text("Your key is stored in this Mac’s Keychain. API usage is billed directly by your provider, separately from a Claude or ChatGPT subscription.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Text("When enabled, meeting text, participant names, coaching context, notes and questions used by AI features go directly to \(provider.title). Audio and transcription stay on your Mac. Cloud AI requires internet access and follows the provider’s data policies.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow AI features to send this text to \(provider.title)", isOn: $consent)
                        .disabled(testing)

                    HStack {
                        Button(testing ? "Working…" : "Test connection") { testConnection() }
                            .disabled(testing || (provider == .claudeAccount ? !accountConnected : (key.isEmpty && !hasSavedKey)))
                        Button("Save and enable") { enable() }
                            .buttonStyle(.borderedProminent)
                            .disabled(testing || !consent || (provider == .claudeAccount ? !accountConnected : (key.isEmpty && !hasSavedKey)))
                    }
                    Text(provider == .claudeAccount
                         ? "Test sends only a short sample prompt using your Claude account. It does not enable meeting text sharing."
                         : "Test sends only a short sample prompt and may incur a small API charge. It does not enable cloud AI.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if hasSavedKey && provider.requiresAPIKey {
                        Button("Remove saved key", role: .destructive) { removeKey() }
                            .disabled(testing)
                    }
                }
                if let status {
                    Text(status).font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                }
            }
            Section("During meetings") {
                Toggle("AI coaching", isOn: $settings.semanticCoachEnabled)
                Text("Provider changes apply to the next meeting and the next on-demand AI request. Switching away from a cloud provider stops future requests to it, including in the current meeting. Requests already sent cannot be recalled. Transcription and built-in coaching continue if cloud AI is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            provider = settings.aiConfiguration.provider
            loadProvider()
        }
        .onChange(of: settings.semanticCoachEnabled) { _, enabled in
            if !enabled { liveSession.shedSessionModel(settings: nil) }
        }
        .onChange(of: provider) { _, _ in loadProvider() }
        .onDisappear { accountTask?.cancel() }
        .onChange(of: model) { _, _ in status = nil }
        .onChange(of: key) { _, _ in status = nil }
    }

    private func loadProvider() {
        accountConnected = false
        key = ""; consent = false; status = nil; isError = false
        model = settings.aiConfiguration.provider == provider
            ? settings.aiConfiguration.model : (provider.models.first ?? "")
        if !provider.models.contains(model) { model = provider.models.first ?? "" }
        do { hasSavedKey = try provider.requiresAPIKey && AIKeychain.read(provider) != nil }
        catch { hasSavedKey = false; fail(error) }
        if provider == .claudeAccount { connectAccount(login: false) }
    }
    private func fail(_ error: Error) { status = error.localizedDescription; isError = true }
    private func enable() {
        if provider == .claudeAccount {
            let configuration = AIConfiguration(provider: provider, model: model)
            testing = true
            accountTask = Task {
                defer { testing = false }
                do {
                    try await ClaudeAccount.checkConnection()
                    try Task.checkCancellation()
                    try settings.enableCloudAI(configuration, key: "")
                    isError = false; status = "Claude account enabled for coaching, reviews and chat."
                } catch is CancellationError { status = "Cancelled." }
                catch { fail(error) }
            }
            return
        }
        do {
            try settings.enableCloudAI(.init(provider: provider, model: model), key: key)
            key = ""; hasSavedKey = true; isError = false
            status = "\(provider.title) enabled."
        } catch { fail(error) }
    }
    private func removeKey() {
        do {
            // Disable first: even a Keychain failure must not leave cloud enabled.
            if settings.aiConfiguration.provider == provider { settings.useLocalAI() }
            try AIKeychain.delete(provider)
            key = ""; hasSavedKey = false; consent = false; isError = false
            status = "Key removed."
        } catch { fail(error) }
    }
    private func connectAccount(login: Bool) {
        testing = true; isError = false
        status = login ? "Complete sign-in in your browser. Waiting for Claude…" : "Checking Claude sign-in…"
        accountTask = Task {
            defer { testing = false }
            do {
                if login { try await ClaudeAccount.login() }
                else { try await ClaudeAccount.checkConnection() }
                try Task.checkCancellation()
                accountConnected = true; isError = false
                status = "Connected. Allow text sharing, then Save and enable."
            } catch is CancellationError { status = "Sign-in cancelled." }
            catch { accountConnected = false; fail(error) }
        }
    }
    private func testConnection() {
        if provider == .claudeAccount {
            let configuration = AIConfiguration(provider: provider, model: model)
            testing = true; status = nil
            accountTask = Task {
                defer { testing = false }
                do {
                    _ = try await ClaudeAccount.complete(configuration: configuration, system: "Reply briefly.",
                                                         user: "Say OK.", maxTokens: 256, requireEnabled: false)
                    isError = false; status = "Connection successful."
                } catch is CancellationError { status = "Test cancelled." }
                catch { fail(error) }
            }
            return
        }
        let configuration = AIConfiguration(provider: provider, model: model)
        do {
            let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let testKey = candidate.isEmpty ? (try AIKeychain.read(provider) ?? "") : candidate
            testing = true; status = nil
            Task {
                defer { testing = false }
                do {
                    _ = try await CloudAI.complete(configuration: configuration, key: testKey,
                                                    system: "Reply briefly.", user: "Say OK.", maxTokens: 32)
                    isError = false; status = "Connection successful."
                } catch { fail(error) }
            }
        } catch { fail(error) }
    }
}
