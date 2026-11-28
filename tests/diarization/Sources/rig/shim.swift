import Foundation

// Shims for app symbols the diarizer files reference, so the real files
// compile unmodified inside the rig.

func mclog(_ msg: String) {
    let ts = String(format: "%.2f", Date().timeIntervalSince(rigStart))
    FileHandle.standardError.write("[\(ts)] \(msg)\n".data(using: .utf8)!)
}

let rigStart = Date()

/// The rig never names a speaker, so nothing is saved; a scratch root keeps
/// it away from the real voice profiles regardless.
enum AppSupport {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("meetmouse-diarization-rig", isDirectory: true)
}
