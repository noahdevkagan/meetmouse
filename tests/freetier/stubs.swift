import Foundation

// FreeTier.bootstrap reads saved sessions; the gate logic under test doesn't.
enum TranscriptSearch {
    static func sessionFiles() -> [URL] { [] }
}
