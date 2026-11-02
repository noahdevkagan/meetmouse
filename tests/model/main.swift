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
func mclog(_ message: String) {}

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
    nonisolated(unsafe) static var deleteCompletesOnTransportError: Bool = true
    nonisolated(unsafe) static var tagsTransportError: Bool = false
    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var tagsErrorBody = Data("Internal Server Error".utf8)
    nonisolated(unsafe) static var tagsSuccessOverride: Data?
    nonisolated(unsafe) static var installedModels: [String] = []
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lastRequest = request
        let url = request.url!

        if url.path == "/api/delete" && Self.deleteTransportError {
            if Self.deleteCompletesOnTransportError,
               let httpBody = request.httpBody ?? request.httpBodyStreamData(),
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
                if let override = Self.tagsSuccessOverride {
                    body = override
                } else {
                    let modelsJson = Self.installedModels.map { name -> [String: Any] in
                        return [
                            "name": name,
                            "size": 3_400_000_000,
                            "details": ["parameter_size": "4B"]
                        ]
                    }
                    body = (try? JSONSerialization.data(withJSONObject: ["models": modelsJson])) ?? Data("{}".utf8)
                }
            } else {
                body = Self.tagsErrorBody
            }
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
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

@MainActor @main struct ModelDeletionTests {
    static func main() async throws {
        let failed = try await run()
        if failed > 0 { exit(1) }
    }

    static func run() async throws -> Int {
        var passed = 0
        var failed = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            guard ok else {
                failed += 1
                print("FAIL: \(label)\(detail.isEmpty ? "" : " — \(detail)")")
                return
            }
            passed += 1
            print("PASS: \(label)")
        }

        guard URLProtocol.registerClass(MockOllamaProtocol.self) else {
            print("FAIL: unable to register mock URL protocol")
            return 1
        }
        let defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        let savedDefaults = defaults.persistentDomain(forName: domain) ?? [:]
        defer {
            URLProtocol.unregisterClass(MockOllamaProtocol.self)
            for key in ["selectedModel", "rubricPath", "launchAtLogin", "modelSelectionNeedsReconciliation"] {
                if let value = savedDefaults[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

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

            // 1d. listModels throws on JSON 500 error instead of returning empty array
            MockOllamaProtocol.tagsStatusCode = 500
            MockOllamaProtocol.tagsErrorBody = Data(#"{"error": "daemon internal failure"}"#.utf8)
            do {
                _ = try await client.listModels()
                check(false, "listModels must throw on HTTP 500 JSON error")
            } catch let OllamaError.serverError(msg) {
                check(msg.contains("daemon internal failure"),
                      "listModels extracts error message from HTTP 500 response")
            } catch {
                check(false, "listModels threw unexpected error on 500: \(error)")
            }

            // 1e. listModels throws on 200 response with missing 'models' field
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.tagsSuccessOverride = Data(#"{"status": "ok"}"#.utf8)
            do {
                _ = try await client.listModels()
                check(false, "listModels must throw when 'models' field is missing")
            } catch let OllamaError.serverError(msg) {
                check(msg.contains("missing 'models' list"),
                      "listModels rejects malformed 200 response without 'models' field")
            } catch {
                check(false, "listModels threw unexpected error on missing models: \(error)")
            }
            MockOllamaProtocol.tagsSuccessOverride = nil
            MockOllamaProtocol.tagsStatusCode = 200
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
                check(vm.selectionNeedsReconciliation,
                      "deleting the last model keeps selection reconciliation pending")
                vm.availableModels = [OllamaModel(name: "stale:1b", size: 1_000_000_000, parameterSize: "1B")]
                vm.selectedModel = "stale:1b"
                check(vm.effectiveModel.isEmpty,
                      "deleting the last model cannot authorize a later stale selection")
            }
            MockOllamaProtocol.installedModels = ["new-model:1b"]
            await vm.refreshModels()
            await MainActor.run {
                check(vm.effectiveModel == "new-model:1b" && !vm.selectionNeedsReconciliation,
                      "a verified model restores selection after deleting the last model")
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
            let vm = await MainActor.run { () -> SettingsViewModel in
                let vm = SettingsViewModel()
                vm.deletingModel = "already-deleting"
                return vm
            }
            await vm.deleteModel("another-model")
            await MainActor.run {
                check(vm.deletingModel == "already-deleting",
                      "duplicate deletion call is ignored while another deletion is in flight")
            }
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

        // 11. A stale snapshot cannot identify a fallback in the active server's store.
        do {
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsTransportError = true
            MockOllamaProtocol.installedModels = ["qwen3.5:4b", "actual-server:1b"]

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
                check(MockOllamaProtocol.installedModels == ["actual-server:1b"],
                      "mock server contains a different remaining model")
                check(vm.selectedModel != "llama3.2:1b",
                      "failed refresh does not select an unverified stale model",
                      "selected: \(vm.selectedModel)")
                check(UserDefaults.standard.string(forKey: "selectedModel") != "llama3.2:1b",
                      "failed refresh does not persist an unverified stale model")
                check(vm.effectiveModel != "llama3.2:1b",
                      "failed refresh does not use an unverified stale effective model",
                      "effective: \(vm.effectiveModel)")
                check(vm.deletionError != nil && vm.deletionError!.contains("could not refresh"),
                      "reconciliation failure surfaced as actionable notice",
                      "got: \(String(describing: vm.deletionError))")
            }
            MockOllamaProtocol.tagsTransportError = false
        }

        // A later successful refresh recovers a selection left pending by a failed one.
        for userPicksFirst in [false, true] {
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.tagsSuccessOverride = nil
            MockOllamaProtocol.tagsTransportError = true
            MockOllamaProtocol.installedModels = ["qwen3.5:4b", "actual-server:1b", "other:1b"]
            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B"),
                    OllamaModel(name: "llama3.2:1b", size: 1_300_000_000, parameterSize: "1B")
                ]
                settings.save()
                return settings
            }
            await vm.deleteModel("qwen3.5:4b")
            let pending = await MainActor.run { vm.selectionNeedsReconciliation }
            check(pending, "failed refresh leaves selection reconciliation pending")
            check(UserDefaults.standard.bool(forKey: "modelSelectionNeedsReconciliation"),
                  "pending reconciliation persists across relaunch")
            let relaunched = await MainActor.run { SettingsViewModel() }
            await MainActor.run {
                relaunched.availableModels = [
                    OllamaModel(name: "llama3.2:1b", size: 1_300_000_000, parameterSize: "1B")
                ]
                check(relaunched.effectiveModel.isEmpty,
                      "relaunch with a pending reconciliation never adopts an unverified model",
                      "effective: \(relaunched.effectiveModel)")
            }

            if userPicksFirst {
                await MainActor.run {
                    vm.selectedModel = "other:1b"
                    vm.save()
                    check(vm.effectiveModel.isEmpty,
                          "user selection cannot use a stale model while reconciliation is pending",
                          "effective: \(vm.effectiveModel)")
                    check(vm.modelForCurrentMemory() == nil,
                          "memory fallback cannot use a stale model while reconciliation is pending")
                }
                let pickedRelaunch = await MainActor.run { SettingsViewModel() }
                await MainActor.run {
                    pickedRelaunch.availableModels = vm.availableModels
                    check(pickedRelaunch.effectiveModel.isEmpty,
                          "relaunch retains pending reconciliation after a user selection")
                }
            }
            MockOllamaProtocol.tagsTransportError = false
            let ready = await vm.prepareAI(ollamaManager: manager)
            await MainActor.run {
                let label = userPicksFirst ? " (user picked first)" : ""
                check(ready, "prepareAI ready after a later successful refresh\(label)")
                check(!vm.selectionNeedsReconciliation
                      && !UserDefaults.standard.bool(forKey: "modelSelectionNeedsReconciliation"),
                      "successful refresh clears pending reconciliation\(label)")
                let installed = MockOllamaProtocol.installedModels
                check(installed.contains(vm.effectiveModel),
                      "recovered effective model is verified on the engine\(label)",
                      "effective: \(vm.effectiveModel), installed: \(installed)")
                if userPicksFirst {
                    check(vm.selectedModel == "other:1b",
                          "recovery keeps the user's own pick")
                } else {
                    check(!vm.selectedModel.isEmpty
                          && UserDefaults.standard.string(forKey: "selectedModel") == vm.selectedModel,
                          "recovered selection persisted without user action",
                          "selected: \(vm.selectedModel)")
                }
            }
        }

        // An empty verified inventory must not permit a later unverified fallback.
        do {
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.tagsSuccessOverride = nil
            MockOllamaProtocol.tagsTransportError = true
            MockOllamaProtocol.installedModels = ["qwen3.5:4b"]
            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B")]
                return settings
            }
            await vm.deleteModel("qwen3.5:4b")
            MockOllamaProtocol.tagsTransportError = false
            await vm.refreshModels()
            await MainActor.run {
                check(vm.selectionNeedsReconciliation && vm.selectedModel.isEmpty,
                      "an empty verified inventory keeps reconciliation pending")
                vm.availableModels = [OllamaModel(name: "llama3.2:1b", size: 1_300_000_000, parameterSize: "1B")]
                vm.selectedModel = "llama3.2:1b"
                check(vm.effectiveModel.isEmpty,
                      "empty verified inventory cannot authorize a later stale model")
            }
            MockOllamaProtocol.installedModels = ["llama3.2:1b"]
            await vm.refreshModels()
            await MainActor.run {
                check(!vm.selectionNeedsReconciliation && vm.effectiveModel == "llama3.2:1b",
                      "a later verified model clears empty-inventory reconciliation")
            }
        }

        // A valid list can establish that a lost response did not delete the target.
        do {
            MockOllamaProtocol.deleteTransportError = true
            MockOllamaProtocol.deleteCompletesOnTransportError = false
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
                check(MockOllamaProtocol.installedModels.contains("qwen3.5:4b")
                      && vm.selectedModel == "qwen3.5:4b"
                      && vm.deletionError?.contains("Failed to delete") == true,
                      "valid refresh confirms that a lost deletion response left the model installed")
            }
            MockOllamaProtocol.deleteTransportError = false
            MockOllamaProtocol.deleteCompletesOnTransportError = true
        }

        // Neither HTTP errors nor malformed successful responses are empty lists.
        for (tagsStatus, lostResponse) in [(500, true), (500, false), (200, true), (200, false)] {
            let response = tagsStatus == 500 ? "HTTP 500" : "missing models field"
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsStatusCode = tagsStatus
            MockOllamaProtocol.tagsErrorBody = Data(#"{"error":"server unavailable"}"#.utf8)
            MockOllamaProtocol.tagsSuccessOverride = tagsStatus == 200
                ? Data(#"{"error":"server unavailable"}"#.utf8) : nil
            MockOllamaProtocol.deleteTransportError = lostResponse
            MockOllamaProtocol.deleteCompletesOnTransportError = false
            MockOllamaProtocol.installedModels = ["qwen3.5:4b", "actual-server:1b"]

            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B"),
                    OllamaModel(name: "actual-server:1b", size: 1_000_000_000, parameterSize: "1B")
                ]
                settings.save()
                return settings
            }

            await vm.deleteModel("qwen3.5:4b")
            await MainActor.run {
                if lostResponse {
                    check(MockOllamaProtocol.installedModels.contains("qwen3.5:4b"),
                          "mock lost response leaves the target installed")
                    check(vm.selectedModel == "qwen3.5:4b"
                          && UserDefaults.standard.string(forKey: "selectedModel") == "qwen3.5:4b",
                          "lost response plus \(response) preserves the selected model",
                          "selected: \(vm.selectedModel)")
                    check(vm.deletionError?.contains("Could not confirm") == true,
                          "lost response plus \(response) reports an uncertain outcome",
                          "error: \(String(describing: vm.deletionError))")
                } else {
                    check(!MockOllamaProtocol.installedModels.contains("qwen3.5:4b"),
                          "mock successful deletion removes the target")
                    check(vm.selectedModel == "",
                          "refresh failure clears selected model to prevent persisting unverified model from wrong store")
                    check(UserDefaults.standard.string(forKey: "selectedModel") == "",
                          "empty selection safely persisted to prevent wrong store adoption")
                    check(vm.deletionError?.contains("could not refresh") == true,
                          "successful deletion plus \(response) reports refresh failure",
                          "error: \(String(describing: vm.deletionError))")
                    check(vm.availableModels.contains { $0.name == "actual-server:1b" },
                          "\(response) does not silently replace the installed list with empty")
                }
            MockOllamaProtocol.deleteTransportError = false
            MockOllamaProtocol.deleteCompletesOnTransportError = true
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.tagsSuccessOverride = nil
          }
        }

        // A malformed entry cannot prove that the target disappeared after a lost response.
        do {
            MockOllamaProtocol.statusCode = 200
            MockOllamaProtocol.tagsStatusCode = 200
            MockOllamaProtocol.tagsSuccessOverride = Data(#"{"models":[{"size":1000000000}]}"#.utf8)
            MockOllamaProtocol.deleteTransportError = true
            MockOllamaProtocol.deleteCompletesOnTransportError = false
            MockOllamaProtocol.installedModels = ["qwen3.5:4b"]
            let manager = await MainActor.run { OllamaManager() }
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.ollamaManager = manager
                settings.selectedModel = "qwen3.5:4b"
                settings.availableModels = [
                    OllamaModel(name: "qwen3.5:4b", size: 3_400_000_000, parameterSize: "4B")
                ]
                settings.save()
                return settings
            }
            await vm.deleteModel("qwen3.5:4b")
            await MainActor.run {
                check(MockOllamaProtocol.installedModels.contains("qwen3.5:4b"),
                      "mock malformed-list case leaves the target installed")
                check(vm.selectedModel == "qwen3.5:4b"
                      && UserDefaults.standard.string(forKey: "selectedModel") == "qwen3.5:4b",
                      "malformed model entry cannot clear the selected model",
                      "selected: \(vm.selectedModel)")
                check(vm.deletionError?.contains("Could not confirm") == true,
                      "malformed model entry reports an uncertain deletion outcome",
                      "error: \(String(describing: vm.deletionError))")
            }
            MockOllamaProtocol.deleteTransportError = false
            MockOllamaProtocol.deleteCompletesOnTransportError = true
            MockOllamaProtocol.tagsSuccessOverride = nil
        }

        UserDefaults.standard.removeObject(forKey: "modelSelectionNeedsReconciliation")
        if recommendedCatalogModel.fitsThisMac {
            let vm = await MainActor.run { () -> SettingsViewModel in
                let settings = SettingsViewModel()
                settings.selectedModel = "deleting:1b"
                settings.deletingModel = "deleting:1b"
                settings.availableModels = [
                    OllamaModel(name: "deleting:1b",
                                size: Int64(ModelMemory.physicalRAMGB) * 1_073_741_824,
                                parameterSize: ""),
                    OllamaModel(name: recommendedCatalogModel.fullName, size: 3_400_000_000, parameterSize: ""),
                    OllamaModel(name: "small-custom:1b", size: 500_000_000, parameterSize: "")
                ]
                return settings
            }
            await MainActor.run {
                check(vm.effectiveModel == recommendedCatalogModel.fullName,
                      "oversized deleting selection resolves to the recommended effective model")
            }
        } else {
            print("SKIP: effective-model fallback requires the recommended model to fit this host")
        }

        print("\nModel deletion checks: \(passed) passed, \(failed) failed.")
        return failed
    }
}
