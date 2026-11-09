import AppKit
import Foundation
import os

/// Manages the embedded Ollama binary lifecycle.
/// Starts it on app launch, stops it on quit. Users never see it.
@MainActor @Observable
final class OllamaManager {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case error(String)
    }

    var status: Status = .stopped

    init() {
        // The embedded server is a plain child process — take it down with
        // the app or every session leaks an `ollama serve`.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }

    private var process: Process?
    private var activePort: Int?
    private var reusedSharedEngine = false
    private let logger = Logger(subsystem: "com.coach.MeetingCoach", category: "OllamaManager")

    /// Last time the engine was auto-restarted after dying unexpectedly.
    /// One restart per window — external kills recover invisibly, a
    /// crash-looping engine still surfaces to the user.
    private var lastAutoRestart = Date.distantPast
    private let autoRestartWindow: TimeInterval = 300

    /// The directory containing ollama and its dylibs inside the app bundle.
    private var ollamaDir: URL? {
        // Strategy 1: Bundle.main.resourceURL/ollama/
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("ollama")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("ollama").path) {
                return candidate
            }
        }
        // Strategy 2: Relative to the executable (../Resources/ollama/)
        if let execURL = Bundle.main.executableURL {
            let candidate = execURL
                .deletingLastPathComponent()        // MacOS/
                .deletingLastPathComponent()        // Contents/
                .appendingPathComponent("Resources/ollama")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("ollama").path) {
                return candidate
            }
        }
        // Strategy 3: Bundle resource lookup
        if let url = Bundle.main.url(forResource: "ollama", withExtension: nil, subdirectory: "ollama") {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    /// The path to the embedded ollama binary.
    private var embeddedOllamaURL: URL? {
        ollamaDir?.appendingPathComponent("ollama")
    }

    /// Data directory for models — stored in Application Support so models
    /// persist across app updates.
    private var modelsDir: URL {
        OllamaLocalEndpoint.modelsDirectory
    }

    /// True when the app's own model store has at least one pulled model.
    private var appHasLocalModels: Bool {
        let manifests = modelsDir.appendingPathComponent("manifests")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: manifests.path)) ?? []
        return !contents.isEmpty
    }

    /// Start the embedded Ollama server on an OS-assigned ephemeral loopback port.
    func start() {
        guard status != .running && status != .starting else { return }

        // Coexistence check: if a MeetMouse-managed server is already running
        // (e.g. spawned by /Applications/MeetMouse.app or a previous window),
        // check whether it answers on its recorded ephemeral port.
        if let existing = OllamaLocalEndpoint.existingManagedServer() {
            if isServerResponding(port: existing.port) {
                logger.info("Using existing MeetMouse ollama on port \(existing.port) (PID \(existing.pid))")
                OllamaLocalEndpoint.setActivePort(existing.port)
                self.activePort = existing.port
                self.reusedSharedEngine = true
                self.status = .running
                return
            }
            // Stale server record from a previous crash — clean it up
            OllamaLocalEndpoint.clearServerState(matchingPID: existing.pid)
            OllamaLocalEndpoint.setActivePort(nil)
        }

        guard let embedded = embeddedOllamaURL, let dir = ollamaDir else {
            // Unvendored dev builds fall back to a system Ollama on 127.0.0.1:11434 without spawning.
            if isServerResponding(port: 11434) {
                logger.info("Dev build without embedded runtime: connected to system Ollama on 127.0.0.1:11434")
                OllamaLocalEndpoint.setActivePort(11434)
                self.activePort = 11434
                self.reusedSharedEngine = true
                self.status = .running
                return
            }
            logger.info("Dev build without embedded runtime: no system Ollama responding on 127.0.0.1:11434")
            status = .error("Local AI engine not running on 127.0.0.1:11434. Start Ollama or run scripts/vendor-ollama.sh.")
            return
        }

        let binaryURL = embedded
        let workingDir = dir
        let port: Int
        do {
            port = try OllamaLocalEndpoint.allocateEphemeralPort()
        } catch {
            status = .error("Could not allocate port for local AI engine: \(error.localizedDescription)")
            return
        }

        status = .starting

        // Ensure models directory exists
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // Make binaries executable if in bundle (in case code signing stripped permissions)
        for bin in ["ollama", "llama-server", "llama-quantize"] {
            let path = workingDir.appendingPathComponent(bin).path
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["serve"]
        proc.currentDirectoryURL = workingDir

        var env = [
            "OLLAMA_HOST": "127.0.0.1:\(port)",
            "OLLAMA_MODELS": modelsDir.path,
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            // Memory posture: the app sends exactly one request at a time
            // (the heartbeat serializes itself), so extra parallel slots
            // would only multiply KV-cache allocations. Flash attention +
            // q8_0 KV halves the cache again with no measurable quality
            // cost at coaching prompt sizes. Applies to the engine we
            // spawn; an adopted system Ollama keeps its own config.
            "OLLAMA_NUM_PARALLEL": "1",
            "OLLAMA_MAX_LOADED_MODELS": "1",
            "OLLAMA_FLASH_ATTENTION": "1",
            "OLLAMA_KV_CACHE_TYPE": "q8_0",
            "OLLAMA_LLM_LIBRARY": workingDir.path,
            // DYLD_LIBRARY_PATH may be stripped by SIP, so also set runner paths
            "DYLD_LIBRARY_PATH": workingDir.path,
            "PATH": workingDir.path + ":/usr/bin:/bin",
        ]
        proc.environment = env

        // Log file for ollama output (helpful for debugging)
        let logFile = modelsDir.appendingPathComponent("ollama.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logFile)
        proc.standardOutput = logHandle ?? FileHandle.nullDevice
        proc.standardError = logHandle ?? FileHandle.nullDevice

        proc.terminationHandler = { [weak self] process in
            logHandle?.closeFile()
            Task { @MainActor in
                guard let self else { return }
                OllamaLocalEndpoint.clearServerState(matchingPID: process.processIdentifier)
                OllamaLocalEndpoint.setActivePort(nil)
                self.process = nil
                self.activePort = nil
                self.reusedSharedEngine = false

                guard self.status == .running || self.status == .starting else { return }
                self.logger.warning("Embedded ollama terminated (code \(process.terminationStatus))")

                // Unexpected death (external kill, engine blip): restart
                // once per window before bothering the user.
                if Date().timeIntervalSince(self.lastAutoRestart) > self.autoRestartWindow {
                    self.lastAutoRestart = Date()
                    self.status = .stopped
                    self.logger.info("Auto-restarting embedded ollama")
                    mclog("[OllamaManager] engine died (code \(process.terminationStatus)) — auto-restarting")
                    self.start()
                    return
                }

                self.status = .error("Local AI engine stopped — instant nudges still work. Retry restores AI nudges.")
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.activePort = port
            self.reusedSharedEngine = false
            OllamaLocalEndpoint.setActivePort(port)
            OllamaLocalEndpoint.writeServerState(pid: proc.processIdentifier, port: port)
            logger.info("Started embedded ollama (PID \(proc.processIdentifier)) on port \(port)")

            // Poll until the server is ready
            Task {
                await waitForReady()
            }
        } catch {
            OllamaLocalEndpoint.setActivePort(nil)
            OllamaLocalEndpoint.clearServerState()
            status = .error("Failed to start: \(error.localizedDescription)")
            logger.error("Failed to start ollama: \(error)")
        }
    }

    /// Start the engine if needed and wait until it accepts requests.
    /// For flows that need Ollama on demand (e.g. model downloads from
    /// onboarding) before any session has lazily started it.
    /// Returns false if the engine can't come up within ~15s.
    func ensureRunning() async -> Bool {
        if status == .running {
            if await OllamaClient().isReachable() { return true }
            status = .stopped
        }
        if status != .starting {
            start()
        }
        for _ in 0..<30 {
            switch status {
            case .running: return true
            case .error: return false
            default: try? await Task.sleep(for: .milliseconds(500))
            }
        }
        return false
    }

    /// Stop the embedded Ollama server. Only called at app termination.
    func stop() {
        if reusedSharedEngine {
            logger.info("Releasing shared MeetMouse ollama without terminating it")
            reusedSharedEngine = false
            activePort = nil
            OllamaLocalEndpoint.setActivePort(nil)
            status = .stopped
            return
        }
        guard let proc = process, proc.isRunning else {
            process = nil
            activePort = nil
            OllamaLocalEndpoint.setActivePort(nil)
            status = .stopped
            return
        }
        logger.info("Stopping embedded ollama (PID \(proc.processIdentifier))")
        OllamaLocalEndpoint.clearServerState(matchingPID: proc.processIdentifier)
        OllamaLocalEndpoint.setActivePort(nil)
        proc.terminate()
        process = nil
        activePort = nil
        status = .stopped
    }

    /// Stops the embedded child process if running, freeing the ephemeral port
    /// when switching to an external provider.
    func stopEmbeddedIfRunning() {
        if let proc = process, proc.isRunning {
            logger.info("Stopping embedded ollama child (PID \(proc.processIdentifier))")
            OllamaLocalEndpoint.clearServerState(matchingPID: proc.processIdentifier)
            OllamaLocalEndpoint.setActivePort(nil)
            proc.terminate()
            process = nil
            activePort = nil
            status = .stopped
        }
    }
    /// Poll until Ollama responds on its API port.
    private func waitForReady() async {
        let client = OllamaClient()
        for attempt in 1...30 {
            try? await Task.sleep(for: .milliseconds(500))
            let reachable = await client.isReachable()
            if reachable {
                logger.info("Ollama ready after \(attempt) attempts")
                status = .running
                return
            }
        }
        // After 15 seconds, give up
        if status == .starting {
            status = .error("Ollama started but not responding")
        }
    }

    /// Quick synchronous check to see if an existing server answers on the port.
    private func isServerResponding(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        var responding = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                responding = true
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.0)
        return responding
    }
}
