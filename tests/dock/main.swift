import AppKit

// Settings → General → Show in Dock: default ON (existing users keep the
// Dock icon), OFF maps to the .accessory policy (menu bar only).
@main
struct DockVisibilityCheck {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "  ok  \(name)" : "  FAIL \(name)")
        if !ok { failures += 1 }
    }

    static func main() {
        let suite = "dock-visibility-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        check(DockVisibility.defaultsKey == "showInDock", "defaults key is stable (shared with @AppStorage)")
        check(DockVisibility.showInDock(defaults), "unset preference keeps the Dock icon")
        defaults.set(false, forKey: DockVisibility.defaultsKey)
        check(!DockVisibility.showInDock(defaults), "saved OFF hides the Dock icon")
        defaults.set(true, forKey: DockVisibility.defaultsKey)
        check(DockVisibility.showInDock(defaults), "saved ON shows the Dock icon")
        check(DockVisibility.policy(showInDock: true) == .regular, "ON uses the regular policy")
        check(DockVisibility.policy(showInDock: false) == .accessory, "OFF uses the accessory policy, never .prohibited")

        if failures > 0 {
            print("DOCK VISIBILITY: \(failures) failure(s)")
            exit(1)
        }
        print("DOCK VISIBILITY: all checks passed")
    }
}
