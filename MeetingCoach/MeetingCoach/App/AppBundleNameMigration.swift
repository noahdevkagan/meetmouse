import Foundation

/// One-time filesystem cleanup for installations that were originally named
/// `MeetingCoach.app`. Sparkle deliberately installs an update back at the
/// existing bundle URL, so changing PRODUCT_NAME updates the bundle contents
/// but does not rename the app users see in Finder.
enum AppBundleNameMigration {
    static let legacyBundleName = "MeetingCoach.app"
    static let currentBundleName = "MeetMouse.app"
    static let bundleIdentifier = "com.coach.MeetingCoach"
    static let currentDisplayName = "MeetMouse"
    static let skipArgument = "--skip-meetmouse-bundle-name-migration"

    struct Plan: Equatable {
        let source: URL
        let destination: URL
    }

    /// Return a rename plan only for the rebranded app running from the exact
    /// legacy filename. The bundle ID intentionally remains legacy for update,
    /// permission, preferences, and data continuity.
    static func plan(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        displayName: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
        fileManager: FileManager = .default
    ) -> Plan? {
        guard !ProcessInfo.processInfo.arguments.contains(skipArgument),
              bundleIdentifier == self.bundleIdentifier,
              displayName == currentDisplayName,
              bundleURL.lastPathComponent == legacyBundleName else {
            return nil
        }

        let destination = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(currentBundleName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { return nil }
        return Plan(source: bundleURL, destination: destination)
    }

    /// Spawn a tiny detached helper before the app quits. Renaming a live app
    /// would leave Bundle.main pointing at a vanished resource path, so the
    /// helper waits for this process to exit, moves the bundle, and relaunches
    /// it from its canonical URL. If the move fails, it reopens the old path
    /// once with a skip argument instead of entering a relaunch loop.
    @discardableResult
    static func launchRenameHelper(
        for plan: Plan,
        parentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
        relaunchExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/open")
    ) throws -> Process {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
        if [ -d "$2" ] && [ ! -e "$3" ] && /bin/mv "$2" "$3"; then
          "$4" "$3"
        elif [ -d "$3" ]; then
          "$4" "$3"
        elif [ -d "$2" ]; then
          "$4" "$2" --args "\(skipArgument)"
        fi
        """

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c", script, "meetmouse-bundle-renamer",
            String(parentPID), plan.source.path, plan.destination.path,
            relaunchExecutableURL.path,
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        return helper
    }
}
