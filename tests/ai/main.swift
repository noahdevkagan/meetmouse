import Foundation

// Local stub proves that cloud routing never falls back to the local transport.
actor OllamaClient {
    init(model: String, timeout: TimeInterval, numCtx: Int, numPredict: Int) {}
    func complete(system: String, user: String) async throws -> String { "local-only" }
}

final class StubHTTP: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var captured: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.captured = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                             httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct Tests {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            count += 1
            print("PASS: \(label)")
        }
        let defaults = UserDefaults(suiteName: "byok-test-\(UUID())")!
        check(AIConfiguration.read(from: defaults).provider == .local, "fresh install stays local")
        defaults.set(Data("bad".utf8), forKey: AIConfiguration.defaultsKey)
        check(AIConfiguration.read(from: defaults).provider == .local, "corrupt config fails closed")
        let openai = AIConfiguration(provider: .openai, model: "gpt-4.1-mini")
        let claude = AIConfiguration(provider: .anthropic, model: "claude-haiku-4-5-20251001")
        openai.save(to: defaults)
        check(AIConfiguration.read(from: defaults) == openai, "cloud preference round trips without key")
        check(AIConfiguration.cloud(from: openai.modelReference) == openai, "pinned reference retains provider and model")
        check(AIConfiguration.cloud(from: "qwen3.5:4b") == nil, "local names are never cloud references")
        defaults.removeObject(forKey: AIConfiguration.defaultsKey)

        check(!LiveCoachingDefault.resolve(in: defaults, isExistingInstall: false), "new install starts with advanced live coaching off")
        check(!LiveCoachingDefault.resolve(in: defaults, isExistingInstall: true), "new-install default survives onboarding marking the install as used")
        defaults.removeObject(forKey: LiveCoachingDefault.key)
        check(LiveCoachingDefault.resolve(in: defaults, isExistingInstall: true), "existing install keeps advanced live coaching on")
        check(LiveCoachingDefault.resolve(in: defaults, isExistingInstall: false), "existing install's default is remembered")
        defaults.set(false, forKey: LiveCoachingDefault.key)
        check(!LiveCoachingDefault.resolve(in: defaults, isExistingInstall: true), "explicit off is never overridden")
        defaults.set(true, forKey: LiveCoachingDefault.key)
        check(LiveCoachingDefault.resolve(in: defaults, isExistingInstall: false), "explicit on is never overridden")
        defaults.removeObject(forKey: LiveCoachingDefault.key)

        // A disposable service isolates these checks from every real app key.
        let keyService = "com.meetmouse.byok-tests.\(UUID())"
        defer { try? AIKeychain.delete(.openai, serviceName: keyService) }
        let absent = try AIKeychain.read(.openai, serviceName: keyService)
        check(absent == nil, "missing Keychain key is absent")
        try AIKeychain.save("test-only-first", for: .openai, serviceName: keyService)
        let first = try AIKeychain.read(.openai, serviceName: keyService)
        check(first == "test-only-first", "Keychain stores API key")
        try AIKeychain.save("test-only-replacement", for: .openai, serviceName: keyService)
        let second = try AIKeychain.read(.openai, serviceName: keyService)
        check(second == "test-only-replacement", "Keychain replaces API key")
        let other = try AIKeychain.read(.anthropic, serviceName: keyService)
        check(other == nil, "provider credentials are isolated")
        try AIKeychain.delete(.openai, serviceName: keyService)
        let removed = try AIKeychain.read(.openai, serviceName: keyService)
        check(removed == nil, "Keychain removes API key")

        let openRequest = try CloudAI.request(configuration: openai, key: "test-key", system: "instructions",
                                               user: "meeting excerpt", maxTokens: 384, timeout: 12)
        let openBody = try JSONSerialization.jsonObject(with: openRequest.httpBody!) as! [String: Any]
        check(openRequest.url?.absoluteString == "https://api.openai.com/v1/responses", "OpenAI fixed HTTPS endpoint")
        check(openRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "OpenAI bearer auth")
        check(openRequest.value(forHTTPHeaderField: "x-api-key") == nil, "no Anthropic credentials on OpenAI")
        check(openBody["store"] as? Bool == false && openBody["stream"] as? Bool == false, "OpenAI storage and streaming disabled")
        check(openBody["instructions"] as? String == "instructions" && openBody["input"] as? String == "meeting excerpt", "OpenAI prompt mapping")
        check(openBody["max_output_tokens"] as? Int == 384, "OpenAI output cap")
        let claudeRequest = try CloudAI.request(configuration: claude, key: "test-key", system: "instructions",
                                                 user: "meeting excerpt", maxTokens: 1500, timeout: 45)
        let claudeBody = try JSONSerialization.jsonObject(with: claudeRequest.httpBody!) as! [String: Any]
        check(claudeRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages", "Claude fixed HTTPS endpoint")
        check(claudeRequest.value(forHTTPHeaderField: "x-api-key") == "test-key" && claudeRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Claude authentication and API version")
        check(claudeBody["system"] as? String == "instructions" && claudeBody["max_tokens"] as? Int == 1500, "Claude prompt and review cap")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        StubHTTP.body = Data(#"{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"A grounded answer"}]}]}"#.utf8)
        let answer = try await CloudAI.complete(configuration: openai, key: "test-key", system: "s", user: "u", session: session)
        check(answer == "A grounded answer", "OpenAI HTTP response ignores reasoning blocks")
        StubHTTP.body = Data(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"A Claude answer"}]}"#.utf8)
        let claudeAnswer = try await CloudAI.complete(configuration: claude, key: "test-key", system: "s", user: "u", session: session)
        check(claudeAnswer == "A Claude answer", "Claude HTTP response extracts only text")
        for status in [301, 400, 401, 403, 404, 429, 500] {
            StubHTTP.status = status
            StubHTTP.body = Data(#"{"error":{"message":"secret-key and private meeting text"}}"#.utf8)
            do {
                _ = try await CloudAI.complete(configuration: openai, key: "test-key", system: "s", user: "u", session: session)
                check(false, "HTTP \(status) must throw")
            } catch {
                check(!error.localizedDescription.contains("secret-key") && !error.localizedDescription.contains("private meeting"), "HTTP \(status) safe actionable error")
            }
        }
        for (provider, body) in [(AIProvider.openai, #"{"status":"incomplete","output":[]}"#),
                                  (.openai, #"{"status":"completed","output":[]}"#),
                                  (.anthropic, #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#),
                                  (.anthropic, "bad JSON")] {
            do { _ = try CloudAI.parse(data: Data(body.utf8), status: 200, provider: provider); check(false, "invalid reply must throw") }
            catch { check(true, "empty, truncated or malformed response rejected") }
        }
        AIConfiguration().save() // CLI test domain, never the app's preferences.
        do {
            _ = try await AIClient(model: openai.modelReference).complete(system: "private", user: "meeting")
            check(false, "disabled cloud must not send")
        } catch { check(error.localizedDescription.contains("disabled"), "disabled cloud rejected before credential/network access") }
        claude.save()
        do {
            _ = try await AIClient(model: openai.modelReference).complete(system: "private", user: "meeting")
            check(false, "old provider must not send after switching")
        } catch { check(error.localizedDescription.contains("changed"), "switching providers revokes old clients") }
        let local = try await AIClient(model: "qwen3.5:4b").complete(system: "s", user: "u")
        check(local == "local-only", "local reference remains local")
        let account = AIConfiguration(provider: .claudeAccount, model: "haiku")
        account.save(to: defaults)
        check(AIConfiguration.read(from: defaults) == account, "Claude account configuration round trips")
        check(AIConfiguration.cloud(from: account.modelReference) == account, "account reference cannot become API/local")
        check(!AIProvider.claudeAccount.requiresAPIKey, "account provider needs no API key")
        do {
            _ = try CloudAI.request(configuration: account, key: "test-key", system: "s", user: "u", maxTokens: 20, timeout: 1)
            check(false, "account must not hit direct API")
        } catch { check(true, "account rejected by direct API transport") }
        AIConfiguration().save()
        do {
            _ = try await AIClient(model: account.modelReference).complete(system: "private", user: "meeting")
            check(false, "disabled account must not launch CLI")
        } catch { check(error.localizedDescription.contains("disabled"), "disabled account rejected before CLI launch") }
        let environment = ClaudeAccount.environment(["ANTHROPIC_API_KEY": "secret", "ANTHROPIC_BASE_URL": "https://evil.invalid",
            "NODE_OPTIONS": "injected", "CLAUDE_CODE_OAUTH_TOKEN": "secret", "HTTPS_PROXY": "proxy", "PATH": "/bad", "LANG": "en_US.UTF-8"])
        check(environment["ANTHROPIC_API_KEY"] == nil && environment["ANTHROPIC_BASE_URL"] == nil && environment["NODE_OPTIONS"] == nil
              && environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil && environment["HTTPS_PROXY"] == nil, "account environment excludes credentials and overrides")
        check(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1" && environment["DISABLE_TELEMETRY"] == "1", "CLI telemetry disabled")
        check(environment["CLAUDE_CODE_DISABLE_ATTACHMENTS"] == "1", "transcript mentions cannot attach local files")
        check(environment["MAX_THINKING_TOKENS"] == "0", "thinking cannot exhaust short coaching output budgets")
        let args = ClaudeAccount.arguments(model: "haiku")
        check(args.contains("--safe-mode") && args.contains("--strict-mcp-config") && args.contains("--no-session-persistence"), "customizations MCP and persistence disabled")
        check(args[args.firstIndex(of: "--tools")! + 1].isEmpty, "CLI has no tools")
        check(ClaudeAccount.isSubscription(Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}"#.utf8)), "subscription authentication accepted")
        for auth in [#"{"loggedIn":false}"#, #"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty"}"#, "bad"] {
            check(!ClaudeAccount.isSubscription(Data(auth.utf8)), "missing API-only or malformed authentication rejected")
        }
        let result = try ClaudeAccount.parse(Data(#"{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"OK"}"#.utf8), exitCode: 0)
        check(result == "OK", "CLI result decoded")
        for body in ["bad", #"{"type":"result","subtype":"success","is_error":false,"result":""}"#,
                     #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"max_tokens","result":"partial"}"#,
                     // Output-limit recovery: success, but `result` is only the last turn's tail.
                     #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","num_turns":3,"result":"NEXT MEETING FOCUS: tail"}"#,
                     #"{"type":"result","subtype":"success","is_error":false,"result":"no turn count"}"#,
                     #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"private meeting secret"}"#] {
            do { _ = try ClaudeAccount.parse(Data(body.utf8), exitCode: 0); check(false, "bad CLI response must throw") }
            catch { check(!error.localizedDescription.contains("private meeting"), "invalid CLI response rejected without leaking payload") }
        }
        let cat = URL(fileURLWithPath: "/bin/cat")
        let payload = Data(repeating: 120, count: 400_000)
        let echoed = try await ClaudeAccount.run(executable: cat, arguments: [], input: payload, timeout: 5)
        check(echoed.data == payload && echoed.code == 0, "large stdin/stdout drained without pipe deadlock")
        do {
            _ = try await ClaudeAccount.run(executable: cat, arguments: [], input: Data(repeating: 120, count: 2_200_000), timeout: 5)
            check(false, "oversized output must fail")
        } catch { check(error.localizedDescription.contains("too much"), "CLI output bounded in memory") }
        let sleeper = URL(fileURLWithPath: "/bin/sleep")
        let started = ContinuousClock.now
        do {
            _ = try await ClaudeAccount.run(executable: sleeper, arguments: ["10"], timeout: 0.1)
            check(false, "timeout must fail")
        } catch { check(error.localizedDescription.contains("timed out") && started.duration(to: .now) < .seconds(3), "timeout kills only owned subprocess promptly") }
        let task = Task { try await ClaudeAccount.run(executable: sleeper, arguments: ["10"], timeout: 15) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; check(false, "cancel must fail") }
        catch is CancellationError { check(true, "cancellation terminates owned subprocess") }
        let early = try await ClaudeAccount.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], input: payload, timeout: 3)
        check(early.code != 0, "early stdin closure cannot crash parent with SIGPIPE")

        // MARK: - Ollama Provider tests
        check(OllamaEndpoint.isLoopback("http://localhost:11434"), "localhost is loopback")
        check(OllamaEndpoint.isLoopback("http://127.0.0.1:11434"), "127.0.0.1 is loopback")
        check(OllamaEndpoint.isLoopback("http://[::1]:11434"), "[::1] is loopback")
        check(!OllamaEndpoint.isLoopback("http://192.168.1.100:11434"), "LAN IP is not loopback")
        check(!OllamaEndpoint.isLoopback("https://ollama.company.com"), "remote domain is not loopback")

        check((try? OllamaEndpoint.normalize("127.0.0.1:11434"))?.absoluteString == "http://127.0.0.1:11434", "normalize adds http scheme")
        check((try? OllamaEndpoint.normalize("http://localhost:11434/api/generate"))?.absoluteString == "http://localhost:11434", "normalize strips /api/generate suffix")
        check((try? OllamaEndpoint.normalize("http://localhost:11434/api/chat"))?.absoluteString == "http://localhost:11434", "normalize strips /api/chat suffix")
        check((try? OllamaEndpoint.normalize("http://localhost:11434/v1/"))?.absoluteString == "http://localhost:11434", "normalize strips /v1 suffix")
        check((try? OllamaEndpoint.normalize("ftp://invalid")) == nil, "normalize rejects non-http protocols")

        let ollamaLocal = AIConfiguration(provider: .ollama, model: "llama3:8b", baseURL: "http://127.0.0.1:11434")
        check(ollamaLocal.isLoopbackOllama, "ollama 127.0.0.1 recognized as loopback")
        check(!ollamaLocal.sendsTextOffDevice, "loopback ollama does not send text off device")

        let ollamaRemote = AIConfiguration(provider: .ollama, model: "llama3:70b", baseURL: "http://192.168.1.50:11434")
        check(!ollamaRemote.isLoopbackOllama, "LAN ollama recognized as remote")
        check(ollamaRemote.sendsTextOffDevice, "remote ollama sends text off device")

        ollamaRemote.save(to: defaults)
        let restoredRemote = AIConfiguration.read(from: defaults)
        check(restoredRemote == ollamaRemote, "remote ollama config round trips in defaults")
        check(restoredRemote.baseURL == "http://192.168.1.50:11434", "baseURL preserved across defaults save")

        let ref = ollamaRemote.modelReference
        check(ref.hasPrefix("cloud:ollama:"), "model reference has cloud:ollama prefix")
        let decodedFromRef = AIConfiguration.cloud(from: ref)
        check(decodedFromRef == ollamaRemote, "model reference preserves baseURL and model")

        check(OllamaProvider.modelNamesMatch(configured: "llama3", installed: "llama3:latest"), "modelNamesMatch handles implicit latest")
        check(OllamaProvider.modelNamesMatch(configured: "llama3:latest", installed: "llama3"), "modelNamesMatch handles explicit latest")
        check(OllamaProvider.modelNamesMatch(configured: "llama3:8b", installed: "llama3:8b"), "modelNamesMatch handles exact match")
        check(!OllamaProvider.modelNamesMatch(configured: "llama3:8b", installed: "llama3:70b"), "modelNamesMatch distinguishes sizes")

        // Ollama HTTP parsing & error handling
        StubHTTP.status = 200
        StubHTTP.body = Data(#"{"models":[{"name":"llama3:8b","size":4500000000,"details":{"parameter_size":"8.0B"}}]}"#.utf8)
        let listed = try await OllamaProvider.listModels(baseURL: URL(string: "http://127.0.0.1:11434")!, session: session)
        check(listed.count == 1 && listed.first?.name == "llama3:8b", "listModels parses models JSON")
        check(listed.first?.parameterSize == "8.0B", "listModels parses parameter size")

        StubHTTP.status = 200
        StubHTTP.body = Data(#"{"message":{"role":"assistant","content":"Ollama response"}}"#.utf8)
        let chatResp = try await OllamaProvider.complete(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            model: "llama3:8b",
            system: "sys",
            user: "usr",
            session: session
        )
        check(chatResp == "Ollama response", "complete parses chat completion")

        // 404 -> modelNotFound
        StubHTTP.status = 404
        StubHTTP.body = Data(#"{"error":"model 'ghost' not found"}"#.utf8)
        do {
            _ = try await OllamaProvider.complete(
                baseURL: URL(string: "http://127.0.0.1:11434")!,
                model: "ghost",
                system: "sys",
                user: "usr",
                session: session
            )
            check(false, "404 must throw")
        } catch let err as OllamaProviderError {
            if case .modelNotFound(let msg) = err {
                check(msg.contains("ghost"), "404 maps to OllamaProviderError.modelNotFound")
            } else {
                check(false, "expected modelNotFound, got \(err)")
            }
        } catch {
            check(false, "expected OllamaProviderError, got \(error)")
        }

        // Chat unsupported error
        StubHTTP.status = 400
        StubHTTP.body = Data(#"{"error":"does not support chat"}"#.utf8)
        do {
            _ = try await OllamaProvider.complete(
                baseURL: URL(string: "http://127.0.0.1:11434")!,
                model: "embed-only",
                system: "sys",
                user: "usr",
                session: session
            )
            check(false, "unsupported chat must throw")
        } catch let err as OllamaProviderError {
            if case .chatUnsupported = err {
                check(true, "error maps to OllamaProviderError.chatUnsupported")
            } else {
                check(false, "expected chatUnsupported, got \(err)")
            }
        } catch {
            check(false, "expected OllamaProviderError, got \(error)")
        }

        // Ollama delete model parsing
        StubHTTP.status = 200
        StubHTTP.body = Data(#"{"status":"success"}"#.utf8)
        do {
            try await OllamaProvider.deleteModel(baseURL: URL(string: "http://127.0.0.1:11434")!, name: "old-model", session: session)
            check(true, "deleteModel succeeds on HTTP 200")
        } catch {
            check(false, "deleteModel failed: \(error)")
        }

        // Notification on missing model
        final class NoticeBox: @unchecked Sendable { var received = false }
        let noticeBox = NoticeBox()
        let observer = NotificationCenter.default.addObserver(forName: OllamaProvider.didDetectMissingModel, object: nil, queue: nil) { note in
            if note.userInfo?["model"] as? String == "missing-test" {
                noticeBox.received = true
            }
        }
        NotificationCenter.default.post(name: OllamaProvider.didDetectMissingModel, object: nil, userInfo: ["model": "missing-test"])
        check(noticeBox.received, "didDetectMissingModel notification posts and delivers model name")
        NotificationCenter.default.removeObserver(observer)

        defaults.removeObject(forKey: AIConfiguration.defaultsKey)
        UserDefaults.standard.removeObject(forKey: AIConfiguration.defaultsKey)
        print("\(count) AI provider checks passed; no live API calls.")
    }
}
