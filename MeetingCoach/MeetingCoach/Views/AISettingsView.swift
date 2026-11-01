import SwiftUI

struct AISettingsView: View {
    @Bindable var settings: SettingsViewModel
    let liveSession: LiveSessionViewModel
    @State private var provider: AIProvider = .local
    @State private var model = ""
    @State private var ollamaURL = OllamaEndpoint.defaultBaseURL
    @State private var refreshingOllama = false
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var consent = false
    @State private var testing = false
    @State private var accountConnected = false
    @State private var accountTask: Task<Void, Never>?
    @State private var status: String?
    @State private var isError = false

    private var activeProviderTitle: String {
        if !settings.usesCloudAI { return "Active: Local (on this Mac)" }
        if settings.aiConfiguration.provider == .ollama {
            return settings.aiConfiguration.isLoopbackOllama
                ? "Active: Ollama (on this Mac)"
                : "Active: Ollama (\(settings.aiConfiguration.baseURL))"
        }
        return "Active: \(settings.aiConfiguration.provider.title)"
    }

    private var activeProviderIcon: String {
        if !settings.usesCloudAI { return "desktopcomputer" }
        if settings.aiConfiguration.provider == .ollama {
            return settings.aiConfiguration.isLoopbackOllama ? "desktopcomputer" : "server.rack"
        }
        return "cloud"
    }

    var body: some View {
        Form {
            Section("AI for meeting notes") {
                Text("Writes your notes after each call and answers questions about your meetings. Nothing here slows your calls unless you turn on advanced live coaching below.")
                    .font(.caption).foregroundStyle(.secondary)
                Label(activeProviderTitle, systemImage: activeProviderIcon)
                    .font(.headline)
                Picker("Provider", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                .disabled(testing || refreshingOllama)

                if provider == .local {
                    Text("Local AI works offline after model downloads. Meeting text stays on your Mac. Manage local models in the main window’s coaching settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.usesCloudAI {
                        Button("Use local AI") {
                            settings.useLocalAI()
                            status = "Local AI enabled. Future external requests are stopped."
                            isError = false
                        }
                    }
                } else if provider == .ollama {
                    TextField("Ollama server URL", text: $ollamaURL)
                        .disabled(testing || refreshingOllama)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button(refreshingOllama ? "Refreshing…" : "Refresh models") {
                            Task { await refreshOllama() }
                        }
                        .disabled(testing || refreshingOllama)

                        Spacer()
                        if OllamaEndpoint.isLoopback(ollamaURL) {
                            Text("Local server")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("Remote server")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

                    if settings.ollamaModels.isEmpty {
                        Text("No models found on Ollama server. Verify the server is running and pull a model.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Download models…") {
                            settings.showModelCatalog = true
                        }
                        .disabled(testing || refreshingOllama)
                    } else {
                        Picker("Model", selection: $model) {
                            ForEach(settings.ollamaModels) { m in
                                Text(m.name + (m.parameterSize.isEmpty ? "" : " (\(m.parameterSize))")).tag(m.name)
                            }
                        }
                        .disabled(testing || refreshingOllama)

                        Button("Download models…") {
                            settings.showModelCatalog = true
                        }
                        .disabled(testing || refreshingOllama)

                        if OllamaEndpoint.isLoopback(ollamaURL),
                           let selected = settings.ollamaModels.first(where: { OllamaProvider.modelNamesMatch(configured: model, installed: $0.name) }),
                           !ModelMemory.fits(selected) {
                            Label("This model may exceed comfortable memory on this Mac (\(ModelMemory.physicalRAMGB) GB RAM).", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }

                    if settings.aiConfiguration.provider == .ollama && settings.ollamaSelectedModelMissing {
                        Label("The selected model '\(settings.aiConfiguration.model)' is not found on your Ollama server. MeetMouse is running with built-in coaching and basic notes until a model is selected.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    if OllamaEndpoint.isLoopback(ollamaURL) {
                        Text("Ollama on this Mac works offline. Meeting text stays on your Mac. No network access or cloud sharing required.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("When enabled, meeting text, participant names, coaching context, notes and questions used by AI features go to your remote Ollama server at \(ollamaURL). Audio and transcription stay on your Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Allow AI features to send this text to \(ollamaURL)", isOn: $consent)
                            .disabled(testing || refreshingOllama)
                    }

                    HStack {
                        Button(testing ? "Working…" : "Test connection") { testConnection() }
                            .disabled(testing || refreshingOllama || model.isEmpty)
                        Button("Save and enable") { enable() }
                            .buttonStyle(.borderedProminent)
                            .disabled(testing || refreshingOllama || model.isEmpty || (!OllamaEndpoint.isLoopback(ollamaURL) && !consent))
                    }
                    Text(OllamaEndpoint.isLoopback(ollamaURL)
                         ? "Test sends only a short sample prompt to your local Ollama instance."
                         : "Test sends only a short sample prompt to your remote Ollama server.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if settings.usesCloudAI {
                        Button("Use local AI") {
                            settings.useLocalAI()
                            status = "Local AI enabled. Ollama provider disabled."
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
                        Text("Uses Claude Code 2.1.280 or later and its official sign-in. Your Claude plan’s usage limits and any enabled extra usage apply. AI notes use a little after each call; advanced live coaching, if you turn it on, uses your allowance throughout a meeting. MeetMouse does not store your Claude login.")
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
                Toggle("Advanced live coaching", isOn: $settings.semanticCoachEnabled)
                Text("Off keeps your calls smooth, and is what most people want. Built-in nudges still run, and AI notes generate after each call.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("On adds AI nudges during calls. \(settings.liveCoachingCostNote)")
                    .font(.caption).foregroundStyle(.secondary)
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
        .onChange(of: ollamaURL) { _, _ in status = nil }
    }

    private func refreshOllama() async {
        guard let url = OllamaEndpoint.normalizeOrNil(ollamaURL) else {
            status = "Invalid server URL. Include http:// or https://"
            isError = true
            return
        }
        refreshingOllama = true
        defer { refreshingOllama = false }
        do {
            let models = try await settings.refreshOllamaModels(baseURL: url.absoluteString)
            if !models.contains(where: { OllamaProvider.modelNamesMatch(configured: model, installed: $0.name) }) {
                model = models.first?.name ?? ""
            }
            isError = false
        } catch {
            fail(error)
        }
    }

    private func loadProvider() {
        accountConnected = false
        key = ""; consent = false; status = nil; isError = false
        if provider == .ollama {
            if !settings.aiConfiguration.baseURL.isEmpty {
                ollamaURL = settings.aiConfiguration.baseURL
            } else {
                ollamaURL = OllamaEndpoint.defaultBaseURL
            }
            if settings.aiConfiguration.provider == .ollama {
                model = settings.aiConfiguration.model
            } else {
                model = settings.ollamaModels.first?.name ?? ""
            }
            Task {
                await refreshOllama()
            }
            return
        }
        model = settings.aiConfiguration.provider == provider
            ? settings.aiConfiguration.model : (provider.models.first ?? "")
        if !provider.models.contains(model) { model = provider.models.first ?? "" }
        do { hasSavedKey = try provider.requiresAPIKey && AIKeychain.read(provider) != nil }
        catch { hasSavedKey = false; fail(error) }
        if provider == .claudeAccount { connectAccount(login: false) }
    }
    private func fail(_ error: Error) { status = error.localizedDescription; isError = true }
    private func enable() {
        if provider == .ollama {
            guard let url = OllamaEndpoint.normalizeOrNil(ollamaURL) else {
                fail(OllamaProviderError.invalidURL(ollamaURL))
                return
            }
            testing = true
            Task {
                defer { testing = false }
                do {
                    try settings.enableOllama(
                        AIConfiguration(provider: .ollama, model: model, baseURL: url.absoluteString),
                        installedModels: settings.ollamaModels
                    )
                    isError = false
                    status = OllamaEndpoint.isLoopback(url)
                        ? "Ollama enabled on this Mac."
                        : "Ollama enabled at \(url.absoluteString)."
                } catch {
                    fail(error)
                }
            }
            return
        }
        if provider == .claudeAccount {
            let configuration = AIConfiguration(provider: provider, model: model)
            testing = true
            accountTask = Task {
                defer { testing = false }
                do {
                    try await ClaudeAccount.checkConnection()
                    try Task.checkCancellation()
                    try settings.enableCloudAI(configuration, key: "")
                    isError = false; status = settings.semanticCoachEnabled ? "Claude account enabled for coaching, reviews and chat." : "Claude account enabled for reviews and chat."
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
        if provider == .ollama {
            guard let url = OllamaEndpoint.normalizeOrNil(ollamaURL) else {
                fail(OllamaProviderError.invalidURL(ollamaURL))
                return
            }
            testing = true; status = nil
            Task {
                defer { testing = false }
                do {
                    let candidate = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty else {
                        throw OllamaProviderError.modelNotFound("No model selected.")
                    }
                    _ = try await OllamaProvider.complete(
                        baseURL: url,
                        model: candidate,
                        system: "Reply briefly.",
                        user: "Say OK.",
                        numPredict: 16
                    )
                    isError = false
                    status = "Connection successful. Model responded."
                } catch {
                    fail(error)
                }
            }
            return
        }
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
