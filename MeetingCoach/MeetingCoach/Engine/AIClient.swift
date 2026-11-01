import Foundation

/// Single text-completion surface for local and explicitly enabled cloud AI.
/// Ollama's loopback-only policy is unchanged. No cloud-to-cloud fallbacks.
actor AIClient {
    private let model: String
    private let timeout: TimeInterval
    private let numCtx: Int
    private let numPredict: Int
    init(model: String, timeout: TimeInterval = 120, numCtx: Int = 8192, numPredict: Int = 512) {
        self.model = model; self.timeout = timeout; self.numCtx = numCtx; self.numPredict = numPredict
    }
    func complete(system: String, user: String) async throws -> String {
        guard let cloud = AIConfiguration.cloud(from: model) else {
            guard !model.hasPrefix("cloud:") else { throw AIError.message("Invalid cloud AI configuration.") }
            return try await OllamaClient(model: model, timeout: timeout, numCtx: numCtx, numPredict: numPredict)
                .complete(system: system, user: user)
        }
        // Re-check consent on EVERY request, including pinned sessions and old
        // clients. Disabling/changing providers stops future transmissions.
        guard AIConfiguration.current == cloud else {
            throw AIError.message("AI provider changed or cloud AI was disabled. Start a new session to use the new selection.")
        }
        if cloud.provider == .claudeAccount {
            return try await ClaudeAccount.complete(configuration: cloud, system: system, user: user,
                                                     maxTokens: numPredict, timeout: timeout)
        }
        guard let key = try AIKeychain.read(cloud.provider), !key.isEmpty else {
            throw AIError.message("Add your \(cloud.provider.title) API key in Settings → AI.")
        }
        try Task.checkCancellation()
        guard AIConfiguration.current == cloud else {
            throw AIError.message("Cloud AI was disabled or changed.")
        }
        return try await CloudAI.complete(configuration: cloud, key: key, system: system, user: user,
                                          maxTokens: numPredict, timeout: timeout)
    }
}

/// Refuse redirects so credentials and meeting text cannot move to another host.
private final class NoAIRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CloudAI {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoAIRedirects(), delegateQueue: nil)
    }()

    static func request(configuration: AIConfiguration, key: String, system: String, user: String,
                        maxTokens: Int, timeout: TimeInterval) throws -> URLRequest {
        guard configuration.provider.requiresAPIKey,
              configuration.provider.models.contains(configuration.model) else {
            throw AIError.message("Choose a supported cloud model.")
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { throw AIError.message("Enter a valid API key.") }
        let url: URL
        var request: URLRequest
        let body: [String: Any]
        switch configuration.provider {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": configuration.model, "system": system,
                    "messages": [["role": "user", "content": user]],
                    "max_tokens": maxTokens, "stream": false]
        case .openai:
            url = URL(string: "https://api.openai.com/v1/responses")!
            request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": configuration.model, "instructions": system, "input": user,
                    "max_output_tokens": maxTokens, "store": false, "stream": false]
        case .gemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(configuration.model):generateContent")!
            request = URLRequest(url: url)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let thinkingLevel = configuration.model == "gemini-3.5-flash-lite" ? "minimal" : "low"
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": [["text": user]]]],
                    "generationConfig": ["thinkingConfig": ["thinkingLevel": thinkingLevel]]]
        case .local, .claudeAccount:
            throw AIError.message("Select a cloud provider first.")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func complete(configuration: AIConfiguration, key: String, system: String, user: String,
                         maxTokens: Int = 512, timeout: TimeInterval = 45,
                         session testSession: URLSession? = nil) async throws -> String {
        let req = try request(configuration: configuration, key: key, system: system, user: user,
                              maxTokens: maxTokens, timeout: timeout)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await (testSession ?? session).data(for: req) }
        catch is CancellationError { throw CancellationError() }
        catch {
            // Never propagate server payloads, credentials or transcript excerpts.
            throw AIError.message("Could not reach \(configuration.provider.title). Check your internet connection and try again.")
        }
        try Task.checkCancellation()
        return try parse(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                         provider: configuration.provider)
    }

    static func parse(data: Data, status: Int, provider: AIProvider) throws -> String {
        guard (200..<300).contains(status) else {
            let reason: String
            switch status {
            case 401, 403: reason = "API key rejected or model access denied. Check your key and permissions."
            case 402, 429: reason = "API quota, billing or rate limit reached. Check your provider account and try later."
            case 400, 404, 422: reason = "The provider could not use this model or request. Check model access in your provider account."
            case 500...599: reason = "The provider is temporarily unavailable. Try again later."
            default: reason = "Request failed (HTTP \(status)). Try again later."
            }
            throw AIError.message("\(provider.title): \(reason)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.message("The AI provider returned an unreadable response.")
        }
        let texts: [String]
        if provider == .anthropic {
            guard json["stop_reason"] as? String != "max_tokens" else {
                throw AIError.message("The AI reply was cut short. Try a shorter request.")
            }
            texts = (json["content"] as? [[String: Any]] ?? []).compactMap {
                $0["type"] as? String == "text" ? $0["text"] as? String : nil
            }
        } else if provider == .openai {
            guard json["status"] as? String == "completed" else {
                throw AIError.message("The AI provider did not finish its reply. Try again.")
            }
            texts = (json["output"] as? [[String: Any]] ?? []).flatMap { item -> [String] in
                guard item["type"] as? String == "message" else { return [] }
                return (item["content"] as? [[String: Any]] ?? []).compactMap {
                    $0["type"] as? String == "output_text" ? $0["text"] as? String : nil
                }
            }
        } else if provider == .gemini {
            if let promptFeedback = json["promptFeedback"] as? [String: Any],
               promptFeedback["blockReason"] != nil {
                throw AIError.message("Google Gemini blocked this response due to content filters. Try another model or local AI.")
            }
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first else {
                throw AIError.message("The AI provider did not finish its reply. Try again.")
            }
            let finishReason = firstCandidate["finishReason"] as? String ?? ""
            let filterReasons: Set<String> = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"]
            if filterReasons.contains(finishReason) {
                throw AIError.message("Google Gemini blocked this response due to content filters. Try another model or local AI.")
            }
            guard finishReason == "STOP" else {
                throw AIError.message("The AI provider did not finish its reply. Try again.")
            }
            guard let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw AIError.message("The AI provider returned an unreadable response.")
            }
            texts = parts.compactMap { part -> String? in
                if part["thought"] as? Bool == true { return nil }
                return part["text"] as? String
            }
        } else {
            texts = []
        }
        let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.message("The AI provider returned no text. Try again.") }
        return text
    }
}
