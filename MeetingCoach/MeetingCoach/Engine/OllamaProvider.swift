import Foundation
import AppKit

struct OllamaModel: Identifiable, Sendable, Equatable {
    let name: String
    let size: Int64
    let parameterSize: String
    var id: String { name }

    var sizeLabel: String {
        let gb = Double(size) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(size) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

enum OllamaEndpoint {
    static let defaultBaseURL = "http://127.0.0.1:11434"

    static func normalize(_ raw: String) throws -> URL {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { candidate = defaultBaseURL }
        if !candidate.contains("://") {
            candidate = "http://" + candidate
        }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            throw OllamaProviderError.invalidURL("Enter a valid http:// or https:// Ollama URL.")
        }
        if components.user != nil || components.password != nil {
            throw OllamaProviderError.invalidURL("Ollama URLs must not contain username or password credentials.")
        }
        if components.query != nil || components.fragment != nil {
            throw OllamaProviderError.invalidURL("Ollama URLs must not contain query parameters or fragments.")
        }

        var path = components.path
        let suffixesToStrip = [
            "/v1/chat/completions",
            "/v1/responses",
            "/v1",
            "/api/chat",
            "/api/generate",
            "/api/tags",
            "/api"
        ]
        var changed = true
        while changed {
            changed = false
            while path.hasSuffix("/") && path.count > 1 {
                path.removeLast()
                changed = true
            }
            for suffix in suffixesToStrip {
                if path.hasSuffix(suffix) {
                    path.removeLast(suffix.count)
                    changed = true
                    break
                }
            }
        }
        if path == "/" { path = "" }

        var cleanedComponents = components
        cleanedComponents.path = path
        guard let url = cleanedComponents.url else {
            throw OllamaProviderError.invalidURL("Invalid Ollama URL.")
        }
        return url
    }

    static func isLoopback(_ url: URL) -> Bool {
        let rawHost = url.host() ?? url.host ?? ""
        let cleanHost = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ["127.0.0.1", "localhost", "::1"].contains(cleanHost.lowercased())
    }

    static func isLoopback(_ string: String) -> Bool {
        guard let url = normalizeOrNil(string) else { return false }
        return isLoopback(url)
    }

    static func normalizeOrNil(_ raw: String?) -> URL? {
        guard let raw else { return try? normalize(defaultBaseURL) }
        return try? normalize(raw)
    }
}

enum OllamaProviderError: LocalizedError, Equatable {
    case invalidURL(String)
    case unreachable(String)
    case atsBlocked(String)
    case modelNotFound(String)
    case chatUnsupported(String)
    case insufficientMemory(String)
    case serverError(String)
    case disabledOrChanged

    var errorDescription: String? {
        switch self {
        case .invalidURL(let msg), .unreachable(let msg), .atsBlocked(let msg),
             .modelNotFound(let msg), .chatUnsupported(let msg),
             .insufficientMemory(let msg), .serverError(let msg):
            return msg
        case .disabledOrChanged:
            return "Ollama provider was disabled or changed. Start a new session to use the new selection."
        }
    }
}

actor SystemOllamaLauncher {
    static let shared = SystemOllamaLauncher()
    private var spawnedProcess: Process?
    nonisolated(unsafe) static var customExecutablePaths: [String]?

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.stopSpawned()
            }
        }
    }

    func stopSpawned() {
        if let proc = spawnedProcess, proc.isRunning {
            proc.terminate()
            spawnedProcess = nil
        }
    }

    static var standardExecutablePaths: [String] {
        if let custom = customExecutablePaths { return custom }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
            "\(home)/.local/bin/ollama"
        ]
    }

    static func findExecutable() -> URL? {
        for path in standardExecutablePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func ensureRunning(for baseURL: URL) async -> Bool {
        guard OllamaEndpoint.isLoopback(baseURL) else { return false }
        if await OllamaProvider.isReachable(baseURL: baseURL) { return true }
        guard let execURL = Self.findExecutable() else {
            return false
        }
        if let current = spawnedProcess, current.isRunning {
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if await OllamaProvider.isReachable(baseURL: baseURL) { return true }
            }
            return false
        }
        let host = baseURL.host() ?? baseURL.host ?? "127.0.0.1"
        let port = baseURL.port ?? 11434
        let proc = Process()
        proc.executableURL = execURL
        proc.arguments = ["serve"]
        var env: [String: String] = [:]
        for k in ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"] {
            if let v = ProcessInfo.processInfo.environment[k] { env[k] = v }
        }
        if let models = ProcessInfo.processInfo.environment["OLLAMA_MODELS"] {
            env["OLLAMA_MODELS"] = models
        }
        env["OLLAMA_HOST"] = "\(host):\(port)"
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            spawnedProcess = proc
        } catch {
            return false
        }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(500))
            if await OllamaProvider.isReachable(baseURL: baseURL) { return true }
        }
        return false
    }
}

enum OllamaProvider {
    static let didDetectMissingModel = Notification.Name("OllamaProvider.didDetectMissingModel")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoAIRedirects(), delegateQueue: nil)
    }()

    static func modelNamesMatch(configured: String, installed: String) -> Bool {
        if configured == installed { return true }
        if !configured.contains(":") && installed == "\(configured):latest" { return true }
        if !installed.contains(":") && configured == "\(installed):latest" { return true }
        return false
    }

    static func isReachable(baseURL: URL, session testSession: URLSession? = nil) async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (data, response) = try await (testSession ?? session).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }
            return (try? JSONSerialization.jsonObject(with: data)) != nil
        } catch {
            return false
        }
    }

    static func listModels(baseURL: URL,
                           autoStartLocal: Bool = true,
                           session testSession: URLSession? = nil) async throws -> [OllamaModel] {
        if autoStartLocal && OllamaEndpoint.isLoopback(baseURL) {
            _ = await SystemOllamaLauncher.shared.ensureRunning(for: baseURL)
        }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (testSession ?? session).data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as URLError where err.code == .appTransportSecurityRequiresSecureConnection {
            throw OllamaProviderError.atsBlocked("Connection blocked by macOS App Transport Security. Remote servers require HTTPS or a local network address.")
        } catch {
            let host = baseURL.host() ?? baseURL.host ?? "server"
            throw OllamaProviderError.unreachable("Could not reach Ollama at \(host). Check that Ollama is running and accessible.")
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw OllamaProviderError.serverError("Ollama returned HTTP \(statusCode).")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw OllamaProviderError.serverError("Ollama returned an unreadable response from /api/tags.")
        }

        return models.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let size = dict["size"] as? Int64 ?? 0
            let details = dict["details"] as? [String: Any] ?? [:]
            let paramSize = details["parameter_size"] as? String ?? ""
            return OllamaModel(name: name, size: size, parameterSize: paramSize)
        }
    }

    static func verifyModelExists(configuration: AIConfiguration,
                                  autoStartLocal: Bool = true,
                                  session testSession: URLSession? = nil) async -> Result<OllamaModel, OllamaProviderError> {
        guard let baseURL = configuration.normalizedOllamaURL else {
            return .failure(.invalidURL("Invalid Ollama URL."))
        }
        do {
            let models = try await listModels(baseURL: baseURL, autoStartLocal: autoStartLocal, session: testSession)
            if let matched = models.first(where: { modelNamesMatch(configured: configuration.model, installed: $0.name) }) {
                return .success(matched)
            }
            NotificationCenter.default.post(name: didDetectMissingModel, object: configuration.model)
            return .failure(.modelNotFound("Model '\(configuration.model)' was not found in Ollama."))
        } catch let err as OllamaProviderError {
            return .failure(err)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    static func runningModels(baseURL: URL, session testSession: URLSession? = nil) async -> [String] {
        let url = baseURL.appendingPathComponent("api/ps")
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, response) = try? await (testSession ?? session).data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    static func preload(configuration: AIConfiguration,
                        keepAlive: String = "30m",
                        numCtx: Int = 4096,
                        session testSession: URLSession? = nil) async -> String? {
        guard configuration.isLoopbackOllama, let baseURL = configuration.normalizedOllamaURL else { return nil }
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "keep_alive": keepAlive,
            "options": ["num_ctx": numCtx],
        ])
        do {
            let (data, response) = try await (testSession ?? session).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    if status == 404 || error.localizedCaseInsensitiveContains("not found") {
                        NotificationCenter.default.post(name: didDetectMissingModel, object: configuration.model)
                    }
                    return error
                }
            }
            if !(200..<300).contains(status) {
                return "HTTP \(status)"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func unloadIfLoaded(configuration: AIConfiguration, session testSession: URLSession? = nil) async {
        guard configuration.isLoopbackOllama, let baseURL = configuration.normalizedOllamaURL else { return }
        let running = await runningModels(baseURL: baseURL, session: testSession)
        guard running.contains(where: { modelNamesMatch(configured: configuration.model, installed: $0) }) else { return }
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "keep_alive": 0,
        ])
        _ = try? await (testSession ?? session).data(for: request)
    }

    static func complete(baseURL: URL,
                         model: String,
                         system: String,
                         user: String,
                         numCtx: Int = 4096,
                         numPredict: Int = 512,
                         timeout: TimeInterval = 60,
                         session testSession: URLSession? = nil) async throws -> String {
        let configuration = AIConfiguration(provider: .ollama, model: model, baseURL: baseURL.absoluteString)
        return try await complete(configuration: configuration,
                                 system: system,
                                 user: user,
                                 numCtx: numCtx,
                                 numPredict: numPredict,
                                 timeout: timeout,
                                 requireEnabled: false,
                                 session: testSession)
    }

    static func complete(configuration: AIConfiguration,
                         system: String,
                         user: String,
                         numCtx: Int = 4096,
                         numPredict: Int = 512,
                         timeout: TimeInterval = 60,
                         requireEnabled: Bool = true,
                         session testSession: URLSession? = nil) async throws -> String {
        guard configuration.provider == .ollama else {
            throw OllamaProviderError.invalidURL("Configuration is not for Ollama provider.")
        }
        guard let baseURL = configuration.normalizedOllamaURL else {
            throw OllamaProviderError.invalidURL("Invalid Ollama server URL.")
        }
        try Task.checkCancellation()
        if requireEnabled && AIConfiguration.current != configuration {
            throw OllamaProviderError.disabledOrChanged
        }

        if configuration.isLoopbackOllama {
            _ = await SystemOllamaLauncher.shared.ensureRunning(for: baseURL)
        }

        try Task.checkCancellation()
        if requireEnabled && AIConfiguration.current != configuration {
            throw OllamaProviderError.disabledOrChanged
        }

        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        var payload: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "options": [
                "temperature": 0.3,
                "num_ctx": numCtx,
                "num_predict": numPredict
            ],
            "stream": false,
            "think": false
        ]
        if configuration.isLoopbackOllama {
            payload["keep_alive"] = "10m"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (testSession ?? session).data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let err as URLError where err.code == .appTransportSecurityRequiresSecureConnection {
            throw OllamaProviderError.atsBlocked("Connection blocked by macOS App Transport Security. Remote servers require HTTPS or a local network address.")
        } catch {
            let host = baseURL.host() ?? baseURL.host ?? "server"
            throw OllamaProviderError.unreachable("Could not reach Ollama at \(host). Check that Ollama is running.")
        }

        try Task.checkCancellation()
        if requireEnabled && AIConfiguration.current != configuration {
            throw OllamaProviderError.disabledOrChanged
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

        if !(200..<300).contains(status) {
            let errorMsg = json["error"] as? String ?? ""
            if status == 404 || errorMsg.localizedCaseInsensitiveContains("not found") {
                NotificationCenter.default.post(name: didDetectMissingModel, object: configuration.model)
                throw OllamaProviderError.modelNotFound("Model '\(configuration.model)' was not found in Ollama. Check your installed models.")
            }
            if status == 400 && (errorMsg.localizedCaseInsensitiveContains("support") || errorMsg.localizedCaseInsensitiveContains("chat")) {
                throw OllamaProviderError.chatUnsupported("Model '\(configuration.model)' does not support chat/completions.")
            }
            if status >= 500 && errorMsg.localizedCaseInsensitiveContains("memory") {
                throw OllamaProviderError.insufficientMemory("Ollama: Not enough memory to run '\(configuration.model)'.")
            }
            if !errorMsg.isEmpty {
                let compact = errorMsg.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                throw OllamaProviderError.serverError("Ollama: \(compact.prefix(160))")
            }
            throw OllamaProviderError.serverError("Ollama request failed (HTTP \(status)).")
        }

        if let errorMsg = json["error"] as? String, !errorMsg.isEmpty {
            if errorMsg.localizedCaseInsensitiveContains("not found") {
                NotificationCenter.default.post(name: didDetectMissingModel, object: configuration.model)
                throw OllamaProviderError.modelNotFound("Model '\(configuration.model)' was not found in Ollama.")
            }
            throw OllamaProviderError.serverError("Ollama error: \(errorMsg)")
        }

        guard let message = json["message"] as? [String: Any] else {
            throw OllamaProviderError.serverError("Ollama returned no message in response.")
        }

        var content = message["content"] as? String ?? ""
        if content.isEmpty, let thinking = message["thinking"] as? String, !thinking.isEmpty {
            content = thinking
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OllamaProviderError.serverError("Ollama returned an empty response. Try again.")
        }
        return trimmed
    }
}
