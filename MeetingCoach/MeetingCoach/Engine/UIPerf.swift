import Foundation

/// Hidden switch restoring the pre-fix recording UI for A/B measurement:
/// `defaults write com.coach.MeetingCoach perfLegacyUI -bool YES` or
/// MM_PERF_LEGACY_UI=1. Read once at launch.
enum UIPerf {
    static let legacy: Bool = {
        if let v = ProcessInfo.processInfo.environment["MM_PERF_LEGACY_UI"] { return v == "1" }
        return UserDefaults.standard.bool(forKey: "perfLegacyUI")
    }()
}
