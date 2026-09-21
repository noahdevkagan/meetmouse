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
                    SecureField(hasSavedKey ? "Saved key — enter to replace" : "Paste API key", text: $key)
                        .disabled(testing)
                        .textContentType(.password)
                    Link("Get an API key ↗", destination: provider.keyURL)
                    Text("Your key is stored in this Mac’s Keychain. API usage is billed directly by your provider, separately from a Claude or ChatGPT subscription.")
                        .font(.caption).foregroundStyle(.secondary)

                    Text("When enabled, meeting text, participant names, coaching context, notes and questions used by AI features go directly to \(provider.title). Audio and transcription stay on your Mac. Cloud AI requires internet access and follows the provider’s data policies.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow AI features to send this text to \(provider.title)", isOn: $consent)
                        .disabled(testing)

                    HStack {
                        Button(testing ? "Testing…" : "Test connection") { testConnection() }
                            .disabled(testing || (key.isEmpty && !hasSavedKey))
                        Button("Save and enable") { enable() }
                            .buttonStyle(.borderedProminent)
                            .disabled(testing || !consent || (key.isEmpty && !hasSavedKey))
                    }
                    Text("Test sends only a short sample prompt and may incur a small API charge. It does not enable cloud AI.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if hasSavedKey {
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
        .onChange(of: model) { _, _ in status = nil }
        .onChange(of: key) { _, _ in status = nil }
    }

    private func loadProvider() {
        key = ""; consent = false; status = nil; isError = false
        model = settings.aiConfiguration.provider == provider
            ? settings.aiConfiguration.model : (provider.models.first ?? "")
        if !provider.models.contains(model) { model = provider.models.first ?? "" }
        do { hasSavedKey = try provider != .local && AIKeychain.read(provider) != nil }
        catch { hasSavedKey = false; fail(error) }
    }
    private func fail(_ error: Error) { status = error.localizedDescription; isError = true }
    private func enable() {
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
    private func testConnection() {
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
