import Foundation

/// What to do when the Parakeet model download fails. Foundation-only so the
/// policy is testable without FluidAudio (`tests/download`).
///
/// Why this exists: some networks keep dropping long transfers from Hugging
/// Face's file servers while everything else (Ollama, app updates) downloads
/// fine. FluidAudio retries each file 4 times and then throws, so one bad
/// stretch ended the whole ~600 MB download with "connection lost". Its
/// partial files (`<file>.partial`) survive the throw, so calling the download
/// again resumes with a Range request. Another round is cheap progress, not a
/// restart, and is worth several tries before telling the user it failed.
enum ParakeetDownloadRetry {
    /// Calls to `AsrModels.download` per attempt, the first one included.
    static let maxRounds = 6

    /// Pause after failed round `round` (1-based) before the next one.
    static func delay(afterRound round: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [3, 10, 20, 40, 60]
        return schedule[min(max(round - 1, 0), schedule.count - 1)]
    }

    /// Network failures that a later round can get past.
    static let transientURLCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorSecureConnectionFailed,
        NSURLErrorResourceUnavailable,
        NSURLErrorCannotLoadFromNetwork,
        NSURLErrorDataNotAllowed,
        NSURLErrorCallIsActive,
        NSURLErrorInternationalRoamingOff,
    ]

    /// True when another round is worth trying: a dropped or unreachable
    /// connection, or a server-side (HTTP 5xx / 429) hiccup.
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let code = urlErrorCode(in: error) {
            return transientURLCodes.contains(code)
        }
        if let status = httpStatus(in: error) {
            return status == 429 || (500...599).contains(status)
        }
        return false
    }

    /// One line for the UI. URL errors read as raw system text ("The network
    /// connection was lost."), which made a server problem look like the
    /// user's own internet was down.
    static func summary(for error: Error) -> String {
        guard let code = urlErrorCode(in: error) else {
            return error.localizedDescription
        }
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
            return "This Mac is offline."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Couldn't find huggingface.co. Check DNS or a firewall."
        case let code where transientURLCodes.contains(code):
            return "The connection to huggingface.co kept dropping."
        default:
            return error.localizedDescription
        }
    }

    /// Hugging Face repo and local folder for each Parakeet version, matching
    /// FluidAudio's `Repo` raw value and `folderName` (not public API).
    static func repoID(versionTag: String) -> String {
        "FluidInference/parakeet-tdt-0.6b-\(versionTag)-coreml"
    }

    static func folderName(versionTag: String) -> String {
        "parakeet-tdt-0.6b-\(versionTag)-coreml"
    }

    /// Fallback for networks where the app's download never gets through:
    /// fetch the model with Python's Hugging Face client (its own HTTP stack,
    /// resumable) into the folder the app loads from. Pressing Retry then
    /// finds it on disk, because the cache check runs before any download.
    static func terminalCommand(versionTag: String) -> String {
        let repo = repoID(versionTag: versionTag)
        let folder = "~/Library/Application Support/FluidAudio/Models/\(folderName(versionTag: versionTag))"
        return "python3 -m pip install --user --upgrade huggingface_hub && "
            + "python3 -c 'import os; from huggingface_hub import snapshot_download; "
            + "snapshot_download(\"\(repo)\", local_dir=os.path.expanduser(\"\(folder)\"))'"
    }

    // MARK: - Digging through wrapped errors

    /// FluidAudio wraps the URLSession error in its own enum
    /// (`DownloadError.downloadFailed(path:underlying:)`), which doesn't
    /// bridge `NSUnderlyingErrorKey`. Walk both the NSError chain and enum
    /// payloads (via Mirror) to find it.
    static func urlErrorCode(in error: Error) -> Int? {
        firstNSError(in: error) { $0.domain == NSURLErrorDomain }?.code
    }

    /// FluidAudio reports HTTP failures as `NSError(domain: "HTTP", code: status)`.
    static func httpStatus(in error: Error) -> Int? {
        firstNSError(in: error) { $0.domain == "HTTP" }?.code
    }

    private static func firstNSError(in value: Any, depth: Int = 0,
                                     where match: (NSError) -> Bool) -> NSError? {
        guard depth < 8 else { return nil }
        if let error = value as? Error {
            let ns = error as NSError
            if match(ns) { return ns }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey],
               let found = firstNSError(in: underlying, depth: depth + 1, where: match) {
                return found
            }
        }
        for child in Mirror(reflecting: value).children {
            if let found = firstNSError(in: child.value, depth: depth + 1, where: match) {
                return found
            }
        }
        return nil
    }
}
