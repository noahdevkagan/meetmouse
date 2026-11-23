import Foundation

// ParakeetDownloadRetry checks. Field case 2026-11: a user's Parakeet v3
// download failed with "connection lost" every time while Qwen and app
// updates downloaded fine. FluidAudio gives up after 4 tries per file, but
// keeps its partial files, so the app should resume a few more rounds before
// showing a failure, and then offer a manual download.

var fail = false
func check(_ name: String, _ ok: Bool) {
    print("download \(name): \(ok ? "PASS" : "FAIL")")
    if !ok { fail = true }
}

// Same shape as FluidAudio's DownloadError: a Swift enum wrapping the
// URLSession error in a labeled payload, with no NSUnderlyingErrorKey.
enum FakeDownloadError: Error {
    case downloadFailed(path: String, underlying: Error)
    case modelNotFound(path: String)
}
struct FakeLoadError: Error { let inner: Error }

let lost = URLError(.networkConnectionLost)
let wrappedLost = FakeDownloadError.downloadFailed(path: "Encoder.mlmodelc/weights", underlying: lost)

// 1. Transient: dropped/unreachable connections, also when wrapped.
check("bare connection lost is transient", ParakeetDownloadRetry.isTransient(lost))
check("wrapped connection lost is transient", ParakeetDownloadRetry.isTransient(wrappedLost))
check("doubly wrapped is transient", ParakeetDownloadRetry.isTransient(FakeLoadError(inner: wrappedLost)))
check("timeout is transient", ParakeetDownloadRetry.isTransient(URLError(.timedOut)))
let nsWrapped = NSError(domain: "Other", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.cannotConnectToHost)])
check("NSUnderlyingError chain is transient", ParakeetDownloadRetry.isTransient(nsWrapped))
let http503 = FakeDownloadError.downloadFailed(path: "x", underlying: NSError(domain: "HTTP", code: 503))
check("HTTP 503 is transient", ParakeetDownloadRetry.isTransient(http503))

// 2. Permanent: no point resuming.
check("cancellation is not transient", !ParakeetDownloadRetry.isTransient(CancellationError()))
check("user cancel is not transient", !ParakeetDownloadRetry.isTransient(URLError(.cancelled)))
check("404 model not found is not transient", !ParakeetDownloadRetry.isTransient(FakeDownloadError.modelNotFound(path: "x")))
let http404 = FakeDownloadError.downloadFailed(path: "x", underlying: NSError(domain: "HTTP", code: 404))
check("HTTP 404 is not transient", !ParakeetDownloadRetry.isTransient(http404))
check("disk full is not transient", !ParakeetDownloadRetry.isTransient(CocoaError(.fileWriteOutOfSpace)))

// 3. Schedule: several rounds, growing pauses, capped.
check("at least 5 rounds", ParakeetDownloadRetry.maxRounds >= 5)
let delays = (1..<ParakeetDownloadRetry.maxRounds).map(ParakeetDownloadRetry.delay(afterRound:))
check("pauses never shrink", zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 })
check("first pause is short", delays.first! <= 5)
check("pause capped at a minute", ParakeetDownloadRetry.delay(afterRound: 99) <= 60)
let total = delays.reduce(0, +)
check("whole retry window under 3 minutes (\(Int(total))s)", total <= 180)

// 4. Summary names the server, not the user's internet.
let summary = ParakeetDownloadRetry.summary(for: wrappedLost)
check("summary names huggingface.co", summary.contains("huggingface.co"))
check("offline reads as offline", ParakeetDownloadRetry.summary(for: URLError(.notConnectedToInternet)) == "This Mac is offline.")
check("other errors keep their text",
      ParakeetDownloadRetry.summary(for: CocoaError(.fileWriteOutOfSpace)) == CocoaError(.fileWriteOutOfSpace).localizedDescription)

// 5. Fallback command targets the folder FluidAudio loads from.
let cmd = ParakeetDownloadRetry.terminalCommand(versionTag: "v3")
check("command has v3 repo", cmd.contains("\"FluidInference/parakeet-tdt-0.6b-v3-coreml\""))
check("command writes to the app's model folder",
      cmd.contains("~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml"))
check("command is one line", !cmd.contains("\n"))
check("v2 repo", ParakeetDownloadRetry.repoID(versionTag: "v2") == "FluidInference/parakeet-tdt-0.6b-v2-coreml")

if fail { print("DOWNLOAD GATE FAILED"); exit(1) }
print("download: all checks passed")
