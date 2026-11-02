import Foundation

// Stubs for leaves SettingsViewModel touches
@MainActor
final class ParakeetDownloadState {
    static let shared = ParakeetDownloadState()
    func startIfNeeded(for engine: TranscriptionEngine) {}
}

struct Rubric {
    static let builtInDefault = Rubric()
    static func migrateToV2(at url: URL, backup: (String) -> Void) {}
}

enum AppSupport {
    static var activeRubricURL: URL { URL(fileURLWithPath: "/tmp/active.yaml") }
    static func ensureLayout() {}
    static func backupActiveRubric(label: String) {}
}

func loadRubric(from url: URL) throws -> Rubric { Rubric() }

@MainActor
final class OllamaManager {
    enum Status: Equatable { case stopped, running, error(String) }
    var status: Status = .stopped
    var shouldSucceedEnsureRunning: Bool = true
    var ensureRunningCalled: Bool = false

    func ensureRunning() async -> Bool {
        ensureRunningCalled = true
        if shouldSucceedEnsureRunning {
            status = .running
            return true
        } else {
            status = .error("Engine failed to start")
            return false
        }
    }
}

final class MockOllamaProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var tagsStatusCode: Int = 200
    nonisolated(unsafe) static var deleteTransportError: Bool = false
    nonisolated(unsafe) static var tagsTransportError: Bool = false
    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var installedModels: [String] = []
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        return request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lastRequest = request
        let url = request.url!

        if url.path == "/api/delete" && Self.deleteTransportError {
            if let httpBody = request.httpBody ?? request.httpBodyStreamData(),
               let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
               let name = json["name"] as? String {
                Self.installedModels.removeAll { $0 == name }
            }
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }

        if url.path == "/api/tags" && Self.tagsTransportError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        var body = Data()
        var code = Self.statusCode

        if url.path == "/api/delete" {
            code = Self.statusCode
            if code == 200 {
                if let httpBody = request.httpBody ?? request.httpBodyStreamData(),
                   let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
                   let name = json["name"] as? String {
                    Self.installedModels.removeAll { $0 == name }
                }
                body = Data("{}".utf8)
            } else {
                body = Self.responseBody
            }
        } else if url.path == "/api/tags" {
            code = Self.tagsStatusCode
            if code == 200 {
                let modelsJson = Self.installedModels.map { name -> [String: Any] in
                    return [
                        "name": name,
                        "size": 3_400_000_000,
                        "details": ["parameter_size": "4B"]
                    ]
                }
                body = (try? JSONSerialization.data(withJSONObject: ["models": modelsJson])) ?? Data("{}".utf8)
            } else {
                body = Data("Internal Server Error".utf8)
            }
        } else {
            body = Self.responseBody
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}

@main struct ModelDeletionTests {
    static func main() async throws {
        var passed = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            guard ok else {
                fatalError("FAIL: \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            }
            passed += 1
            print("PASS: \(label)")
        }

        URLProtocol.registerClass(MockOllamaProtocol.self)
        defer { URLProtocol.unregisterClass(MockOllamaProtocol.self) }

        // 1. OllamaClient.deleteModel status handling
        do {
            let client = OllamaClient(model: "qwen3.5:4b")

            // 1a. Successful deletion (200 OK)
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.responseBody = Data("{}".utf8)
            MockOllamaProtocol.installedModels = ["qwen3.5:4b"]
            try await client.deleteModel(name: "qwen3.5:4b")
            check(MockOllamaProtocol.lastRequest?.httpMethod == "DELETE",
                  "OllamaClient uses DELETE method")
            check(MockOllamaProtocol.lastRequest?.url?.path == "/api/delete",
                  "OllamaClient targets /api/delete")

            // 1b. 400 with JSON error message
            MockOllamaProtocol.statusCode = 400
            MockOllamaProtocol.responseBody = Data(#"{"error": "model 'qwen3.5:4b' not found"}"#.utf8)
            do {
                try await client.deleteModel(name: "qwen3.5:4b")
                check(false, "OllamaClient must throw on 400")
            } catch let OllamaError.serverError(msg) {
                check(msg == "model 'qwen3.5:4b' not found",
                      "OllamaClient extracts error field from JSON",
                      "received: \(msg)")
            } catch {
                check(false, "OllamaClient threw unexpected error: \(error)")
            }

            // 1c. 500 without JSON
            MockOllamaProtocol.statusCode = 500
            MockOllamaProtocol.responseBody = Data("Internal Server Error".utf8)
            do {
                try await client.deleteModel(name: "qwen3.5:4b")
                check(false, "OllamaClient must throw on 500")
            } catch let OllamaError.serverError(msg) {
                check(msg.contains("500"),
                      "OllamaClient formats status code error when body is not JSON",
                      "received: \(msg)")
            } catch {
                check(false, "OllamaClient threw unexpected error: \(error)")
            }
        }

        // 2. SettingsViewModel.deleteModel — Engine failure
        do {
            let manager = await MainActor.run { () -> OllamaManager in
                let mgr = OllamaManager()
                mgr.shouldSucceedEnsureRunning = false
                return mgr
            }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B")
                ]
                return settings
            }

            await vm.deleteModel("qwen3.5:4b")
            await MainActor.run {
                check(manager.ensureRunningCalled, "deleteModel verified engine status")
                check(vm.deletionError != nil && vm.deletionError!.contains("Could not start"),
                      "engine startup failure sets actionable deletionError",
                      "error: \(String(describing: vm.deletionError))")
                check(vm.deletingModel == nil, "deletingModel cleared on engine failure")
                check(vm.availableModels.count == 1, "availableModels preserved on engine failure")
                check(vm.selectedModel == "qwen3.5:4b", "selectedModel preserved on engine failure")
            }
        }

        // 3. SettingsViewModel.deleteModel — Selected model deletion & memory fallback
        do {
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.responseBody = Data("{}".utf8)
            MockOllamaProtocol.installedModels = ["qwen3.5:9b", "qwen3.5:4b", "llama3.2:1b"]

            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:9b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:9b", size: 6_600_000_000, parameterSize: "9B"),
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B"),
                    OllamaModel(name: "llama3.2:1b", size: 1_300_000_000, parameterSize: "1B")
                ]
                return settings
            }

            await vm.deleteModel("qwen3.5:9b")

            await MainActor.run {
                check(!vm.availableModels.contains { $0.name == "qwen3.5:9b" },
                      "deleted model removed from availableModels")
                check(vm.selectedModel == "qwen3.5:4b" || vm.selectedModel == "llama3.2:1b",
                      "selection falls back to a fitting installed model",
                      "got: \(vm.selectedModel)")
                check(vm.deletingModel == nil, "deletingModel cleared after deletion")
                check(vm.deletionError == nil, "no deletion error on success")
                check(UserDefaults.standard.string(forKey: "selectedModel") == vm.selectedModel,
                      "new selection persisted to UserDefaults")
            }
        }

        // 4. SettingsViewModel.deleteModel — Last model deletion
        do {
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.responseBody = Data("{}".utf8)
            MockOllamaProtocol.installedModels = ["qwen3.5:4b"]

            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B")
                ]
                return settings
            }

            await vm.deleteModel("qwen3.5:4b")

            await MainActor.run {
                check(vm.availableModels.isEmpty, "last model removed from availableModels")
                check(vm.selectedModel == "",
                      "selection cleared when no models remain",
                      "got: '\(vm.selectedModel)'")
                check(UserDefaults.standard.string(forKey: "selectedModel") == "",
                      "empty selection persisted to UserDefaults")
            }
        }

        // 5. SettingsViewModel.deleteModel — Unselected model deletion preserves selection
        do {
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.responseBody = Data("{}".utf8)
            MockOllamaProtocol.installedModels = ["qwen3.5:4b", "llama3.2:1b"]

            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B"),
                    OllamaModel(name: "llama3.2:1b", size: 1_300_000_000, parameterSize: "1B")
                ]
                return settings
            }

            await vm.deleteModel("llama3.2:1b")

            await MainActor.run {
                check(vm.availableModels.count == 1, "unselected model removed")
                check(vm.selectedModel == "qwen3.5:4b",
                      "unselected model deletion preserves active selection")
            }
        }

        // 6. SettingsViewModel.deleteModel — Server failure sets deletionError
        do {
            MockOllamaProtocol.statusCode = 404
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.responseBody = Data(#"{"error": "model 'not-found' not found"}"#.utf8)
            MockOllamaProtocol.installedModels = ["qwen3.5:4b"]

            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B")
                ]
                return settings
            }

            await vm.deleteModel("not-found")

            await MainActor.run {
                check(vm.deletionError != nil && vm.deletionError!.contains("not found"),
                      "server error surfaced in deletionError",
                      "error: \(String(describing: vm.deletionError))")
                check(vm.availableModels.count == 1, "installed list preserved on failure")
                check(vm.selectedModel == "qwen3.5:4b", "selection preserved on failure")
            }
        }

        // 7. Duplicate deletion prevention
        do {
            await MainActor.run {
                let vm = SettingsViewModel()
                vm.deletingModel = "already-deleting"
                Task {
                    await vm.deleteModel("another-model")
                    check(vm.deletingModel == "already-deleting",
                          "duplicate deletion call is ignored while another deletion is in flight")
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        // 8. Meeting protection race interlock: canDelete rejects when in use
        do {
            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B")
                ]
                return settings
            }

            // Simulate meeting started and acquired model right before deleteModel was called
            await vm.deleteModel("qwen3.5:4b") {
                return (false, "In use by active meeting")
            }

            await MainActor.run {
                check(vm.deletingModel == nil, "deletingModel not set when ownership check rejects")
                check(vm.deletionError == "In use by active meeting",
                      "rejection reason surfaced in deletionError",
                      "got: \(String(describing: vm.deletionError))")
                check(vm.availableModels.count == 1, "model preserved when ownership check rejects")
            }
        }

        // 9. Lost deletion response recovered via engine list
        do {
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.deleteTransportError = true
            MockOllamaProtocol.tagsTransportError = false
            MockOllamaProtocol.installedModels = ["qwen3.5:4b", "llama3.2:1b"]

            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B"),
                    OllamaModel(name: "llama3.2:1b", size: 1_300_000_000, parameterSize: "1B")
                ]
                return settings
            }

            await vm.deleteModel("qwen3.5:4b")

            await MainActor.run {
                check(!vm.availableModels.contains { $0.name == "qwen3.5:4b" },
                      "lost response model confirmed deleted via engine query")
                check(vm.selectedModel == "llama3.2:1b",
                      "selection reconciled following confirmed deletion")
                check(vm.deletionError == nil,
                      "no false failure reported when engine confirms model is deleted")
            }
            MockOllamaProtocol.deleteTransportError = false
        }

        // 10. Lost deletion response with failed engine query reports uncertain outcome
        do {
            MockOllamaProtocol.deleteTransportError = true
            MockOllamaProtocol.tagsTransportError = true
            MockOllamaProtocol.installedModels = ["qwen3.5:4b"]

            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B")
                ]
                return settings
            }

            await vm.deleteModel("qwen3.5:4b")

            await MainActor.run {
                check(vm.deletionError != nil && vm.deletionError!.contains("Could not confirm"),
                      "indeterminate result reported as uncertain rather than false success/failure",
                      "got: \(String(describing: vm.deletionError))")
                check(vm.availableModels.count == 1, "model list kept intact on uncertain outcome")
            }
            MockOllamaProtocol.deleteTransportError = false
            MockOllamaProtocol.tagsTransportError = false
        }

        // 11. Refresh failure after successful deletion reports reconciliation warning without corrupting selection
        do {
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsTransportError = true
            MockOllamaProtocol.installedModels = ["llama3.2:1b"]

            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B"),
                    OllamaModel(name: "llama3.2:1b", size: 1_300_000_000, parameterSize: "1B")
                ]
                return settings
            }

            await vm.deleteModel("qwen3.5:4b")

            await MainActor.run {
                check(!vm.availableModels.contains { $0.name == "qwen3.5:4b" },
                      "deleted model removed from memory snapshot")
                check(vm.selectedModel == "llama3.2:1b",
                      "selection safely updated to remaining known model")
                check(vm.deletionError != nil && vm.deletionError!.contains("could not refresh"),
                      "reconciliation failure surfaced as actionable notice",
                      "got: \(String(describing: vm.deletionError))")
            }
            MockOllamaProtocol.tagsTransportError = false
        }

        print("\nAll \(passed) model deletion checks passed.")
    }
}
