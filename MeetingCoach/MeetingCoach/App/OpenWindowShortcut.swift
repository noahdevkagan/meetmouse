import Carbon
import SwiftUI

/// Carbon hotkeys work across apps without monitoring keystrokes or requiring
/// Accessibility permission. Owned for the app lifetime, not by its main window.
@MainActor
@Observable
final class OpenWindowShortcut {
    static let shared = OpenWindowShortcut()
    static let defaultsKey = "openWindowShortcutEnabled"
    private(set) var registrationError: String?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private let identifier = EventHotKeyID(signature: 0x4D4D4F50, id: 1)

    func configure(enabled: Bool, action: @escaping () -> Void) {
        self.action = action
        unregister()
        registrationError = nil
        guard enabled else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.signature == 0x4D4D4F50, pressed.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in OpenWindowShortcut.shared.action?() }
            return noErr
        }, 1, &eventType, nil, &handler)
        guard handlerStatus == noErr else {
            registrationError = "Couldn’t enable the shortcut. Turn it off and on to try again."
            unregister()
            return
        }
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | cmdKey),
                                         identifier, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            registrationError = "Control–Command–M is unavailable. Another app may be using it. Free the shortcut, then turn it off and on here."
            unregister()
        }
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
}
