import Foundation
import Carbon
import Cocoa

/// Registers a single global hotkey for play/pause via the Carbon
/// `RegisterEventHotKey` API. Posts a `PlayPauseHotkey` notification when
/// pressed.
///
/// F8 is the default. Note: macOS owns the hardware F8 media key by default.
/// For this hotkey to fire on F8, the user must enable "Use F1, F2, etc. keys
/// as standard function keys" in System Settings → Keyboard, OR pick a
/// different binding.
final class HotkeyManager {
    static let playPauseNotification = Notification.Name("PlayPauseHotkey")

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    /// kVK_F8 = 100
    private(set) var keyCode: UInt32
    private(set) var modifiers: UInt32

    private let keyCodeDefaultsKey = "Hotkey.PlayPause.KeyCode"
    private let modifiersDefaultsKey = "Hotkey.PlayPause.Modifiers"

    init() {
        let storedKeyCode = UserDefaults.standard.object(forKey: keyCodeDefaultsKey) as? Int
        let storedModifiers = UserDefaults.standard.object(forKey: modifiersDefaultsKey) as? UInt32
        // Default to F8 with no modifiers.
        self.keyCode = UInt32(storedKeyCode ?? Int(kVK_F8))
        self.modifiers = storedModifiers ?? 0
        installHandler()
        register()
    }

    deinit {
        unregister()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if hotKeyID.id == 1 {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: HotkeyManager.playPauseNotification,
                            object: nil
                        )
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    private func register() {
        unregister()
        var hotKeyID = EventHotKeyID(signature: fourCharCode("sncl"), id: 1)
        let status = RegisterEventHotKey(
            keyCode, modifiers,
            hotKeyID, GetApplicationEventTarget(),
            0, &hotKeyRef
        )
        if status != noErr {
            logWarning("HotkeyManager: failed to register hotkey (status=\(status)). On F8, this is expected unless 'Use F1, F2 as standard function keys' is enabled in System Settings.")
        } else {
            logInfo("HotkeyManager: registered play/pause hotkey (keyCode=\(keyCode), modifiers=\(modifiers))")
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    func setHotkey(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: keyCodeDefaultsKey)
        UserDefaults.standard.set(modifiers, forKey: modifiersDefaultsKey)
        register()
    }

    private func fourCharCode(_ s: String) -> FourCharCode {
        let chars = s.utf8.prefix(4)
        var result: UInt32 = 0
        for c in chars { result = (result << 8) | UInt32(c) }
        return FourCharCode(result)
    }
}
