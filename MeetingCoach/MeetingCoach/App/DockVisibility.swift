import AppKit

/// "Show in Dock" (Settings → General). Off runs MeetMouse from the menu bar
/// only by switching the activation policy to `.accessory` at runtime.
/// Info.plist (LSUIElement), signing and the bundle are untouched, so the
/// code signature and the Mic / Screen Recording grants stay valid.
///
/// The main window does NOT switch the app back to `.regular` while it is
/// open: the user asked for no Dock icon at all, and flipping the policy on
/// every open/close makes the icon pop in and out and can drop focus when
/// returning to `.accessory`. Instead every "open the main window" path
/// activates the app explicitly (accessory apps are never activated for
/// free), so the window still comes to front with keyboard focus.
enum DockVisibility {
    static let defaultsKey = "showInDock"

    /// Default ON: existing users keep the Dock icon until they opt out.
    static func showInDock(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func policy(showInDock: Bool) -> NSApplication.ActivationPolicy {
        showInDock ? .regular : .accessory
    }

    /// Applies the saved choice. Called before launch finishes (so a hidden
    /// icon never flashes in the Dock) and whenever the toggle changes.
    @MainActor
    static func apply(showInDock: Bool = DockVisibility.showInDock()) {
        let target = policy(showInDock: showInDock)
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        // Leaving .regular deactivates the app; the toggle is flipped from the
        // Settings window, which should stay in front and keep focus.
        if target == .accessory, NSApp.windows.contains(where: { $0.isVisible }) {
            Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// Bring a window opened with `openWindow(id:)` to the front with focus.
    /// Needed for accessory apps (no Dock icon): opening a window does not
    /// activate them, so it would land behind the frontmost app. Harmless
    /// with a Dock icon. The window is created asynchronously by SwiftUI, so
    /// the key-window step runs on the next turn of the run loop.
    @MainActor
    static func bringToFront(windowID: String = "main") {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: {
                ($0.identifier?.rawValue ?? "").hasPrefix(windowID) && $0.isVisible
            }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
