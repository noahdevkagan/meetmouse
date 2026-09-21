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
        UserDefaults.standard.removeObject(forKey: AIConfiguration.defaultsKey)
        print("\(count) AI provider checks passed; no live API calls.")
    }
}
