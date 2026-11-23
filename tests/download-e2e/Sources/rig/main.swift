import FluidAudio
import Foundation

// Modes (one per process, so FluidAudio's session reads https_proxy fresh):
//   single   one bare AsrModels.download call: what the app did before the fix
//   app      the app's real ParakeetDownloadState.prepare(for: .parakeetV3)
//   load     load the cached v3 models (proves the files on disk are usable)
//   command  print the Terminal fallback command shown in the app
//   path     print the folder FluidAudio caches v3 in
// Prints "RESULT <mode> ok|fail ..." and exits 0 on ok, 1 on fail.

let mode = CommandLine.arguments.dropFirst().first ?? "app"

func finish(_ ok: Bool, _ detail: String) -> Never {
    print("RESULT \(mode) \(ok ? "ok" : "fail") \(detail)")
    exit(ok ? 0 : 1)
}

Task { @MainActor in
    let started = Date()
    func elapsed() -> String { String(format: "%.0fs", Date().timeIntervalSince(started)) }
    switch mode {
    case "single":
        do {
            _ = try await AsrModels.download(version: .v3)
            finish(true, "cached=\(ParakeetEngine.isCachedOnDisk(.v3)) \(elapsed())")
        } catch {
            finish(false, "transient=\(ParakeetDownloadRetry.isTransient(error)) "
                + "summary=\"\(ParakeetDownloadRetry.summary(for: error))\" error=\(error) \(elapsed())")
        }
    case "app":
        let ok = await ParakeetDownloadState.shared.prepare(for: .parakeetV3)
        let cached = ParakeetEngine.isCachedOnDisk(.v3)
        let message = ParakeetDownloadState.shared.failureMessage(for: .parakeetV3) ?? "-"
        finish(ok && cached, "prepared=\(ok) cached=\(cached) failure=\"\(message)\" \(elapsed())")
    case "load":
        let dir = AsrModels.defaultCacheDirectory(for: .v3)
        guard ParakeetEngine.isCachedOnDisk(.v3) else {
            finish(false, "models missing at \(dir.path)")
        }
        do {
            let models = try await AsrModels.load(from: dir, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            finish(true, "loaded from \(dir.path) \(elapsed())")
        } catch {
            finish(false, "load error=\(error)")
        }
    case "command":
        print(TranscriptionEngine.parakeetV3.parakeetManualDownloadCommand ?? "")
        exit(0)
    case "path":
        print(AsrModels.defaultCacheDirectory(for: .v3).path)
        exit(0)
    default:
        finish(false, "unknown mode")
    }
}
dispatchMain()
