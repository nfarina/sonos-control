import Foundation
import Carbon
import Cocoa
import Combine

/// Identifies a single bindable shortcut. The HotkeyManager owns the registry
/// and posts a matching Notification when the user presses the keys.
enum HotkeyAction: String, CaseIterable, Identifiable {
    case globalPlayPause
    case inAppPlayPause
    case inAppVolumeUp
    case inAppVolumeDown

    var id: String { rawValue }

    var notificationName: Notification.Name {
        Notification.Name("Hotkey.\(rawValue)")
    }

    var displayName: String {
        switch self {
        case .globalPlayPause: return "Play/Pause (global)"
        case .inAppPlayPause:  return "Play/Pause"
        case .inAppVolumeUp:   return "Volume Up"
        case .inAppVolumeDown: return "Volume Down"
        }
    }

    /// Global hotkeys are registered system-wide via Carbon; in-app ones only
    /// fire when our windows are active (e.g. when the popup is open).
    var scope: HotkeyScope {
        switch self {
        case .globalPlayPause: return .global
        default: return .inApp
        }
    }

    /// Defaults applied on first launch (or after a reset).
    var defaultKeyCode: UInt32 {
        switch self {
        case .globalPlayPause: return UInt32(kVK_F8)
        case .inAppPlayPause:  return UInt32(kVK_ANSI_P)
        case .inAppVolumeUp:   return UInt32(kVK_ANSI_Equal)
        case .inAppVolumeDown: return UInt32(kVK_ANSI_Minus)
        }
    }

    var defaultModifiers: UInt32 {
        switch self {
        case .globalPlayPause: return 0
        default: return UInt32(cmdKey)
        }
    }
}

enum HotkeyScope {
    case global, inApp
}

/// One configurable binding. `keyCode` is a Carbon virtual keycode (kVK_*);
/// `modifiers` is the Carbon modifier mask (cmdKey, optionKey, etc.).
struct HotkeyBinding: Identifiable, Equatable {
    let action: HotkeyAction
    var keyCode: UInt32
    var modifiers: UInt32

    var id: String { action.id }

    var displayString: String {
        HotkeyManager.symbols(forCarbonModifiers: modifiers)
            + (HotkeyManager.keyName(fromKeyCode: keyCode) ?? "?")
    }
}

@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var bindings: [HotkeyAction: HotkeyBinding] = [:]

    private var eventHandler: EventHandlerRef?
    private var globalRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var localMonitor: Any?

    /// Stable Carbon hot-key IDs per action — needed to route the OS-level
    /// callback back to the right binding.
    private static let actionToHotkeyID: [HotkeyAction: UInt32] = {
        var map: [HotkeyAction: UInt32] = [:]
        for (i, action) in HotkeyAction.allCases.enumerated() {
            map[action] = UInt32(i + 1)
        }
        return map
    }()
    private static let hotkeyIDToAction: [UInt32: HotkeyAction] = {
        var map: [UInt32: HotkeyAction] = [:]
        for (action, id) in actionToHotkeyID {
            map[id] = action
        }
        return map
    }()

    init() {
        loadBindings()
        installCarbonHandler()
        installLocalMonitor()
        registerAllGlobals()
    }

    deinit {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        for ref in globalRefs.values {
            UnregisterEventHotKey(ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    // MARK: - Public API

    /// Update a binding's keys + re-register if it's a global hotkey.
    func setBinding(_ action: HotkeyAction, keyCode: UInt32, modifiers: UInt32) {
        var binding = bindings[action] ?? HotkeyBinding(action: action, keyCode: keyCode, modifiers: modifiers)
        binding.keyCode = keyCode
        binding.modifiers = modifiers
        bindings[action] = binding
        persist(action: action)
        if action.scope == .global {
            registerGlobal(action)
        }
    }

    /// Restore default keys for one binding.
    func reset(_ action: HotkeyAction) {
        setBinding(action,
                   keyCode: action.defaultKeyCode,
                   modifiers: action.defaultModifiers)
    }

    // MARK: - Loading / persistence

    private func loadBindings() {
        var map: [HotkeyAction: HotkeyBinding] = [:]
        for action in HotkeyAction.allCases {
            let keyCode = UInt32(UserDefaults.standard.object(forKey: keyCodeKey(action)) as? Int
                                ?? Int(action.defaultKeyCode))
            let modifiers = UserDefaults.standard.object(forKey: modifiersKey(action)) as? UInt32
                            ?? action.defaultModifiers
            map[action] = HotkeyBinding(action: action, keyCode: keyCode, modifiers: modifiers)
        }
        bindings = map
    }

    private func persist(action: HotkeyAction) {
        guard let binding = bindings[action] else { return }
        UserDefaults.standard.set(Int(binding.keyCode), forKey: keyCodeKey(action))
        UserDefaults.standard.set(binding.modifiers, forKey: modifiersKey(action))
    }

    private func keyCodeKey(_ action: HotkeyAction) -> String { "Hotkey.\(action.rawValue).keyCode" }
    private func modifiersKey(_ action: HotkeyAction) -> String { "Hotkey.\(action.rawValue).modifiers" }

    // MARK: - Global hotkeys (Carbon)

    private func installCarbonHandler() {
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
                if let action = HotkeyManager.hotkeyIDToAction[hotKeyID.id] {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: action.notificationName, object: nil)
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

    private func registerAllGlobals() {
        for action in HotkeyAction.allCases where action.scope == .global {
            registerGlobal(action)
        }
    }

    private func registerGlobal(_ action: HotkeyAction) {
        // Unregister any prior registration first.
        if let existing = globalRefs[action] {
            UnregisterEventHotKey(existing)
            globalRefs.removeValue(forKey: action)
        }
        guard let binding = bindings[action], let hotkeyID = Self.actionToHotkeyID[action] else { return }
        let id = EventHotKeyID(signature: fourCharCode("sncl"), id: hotkeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode, binding.modifiers,
            id, GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref {
            globalRefs[action] = ref
            logInfo("HotkeyManager: registered \(action.rawValue) → \(binding.displayString)")
        } else {
            logWarning("HotkeyManager: failed to register \(action.rawValue) (status=\(status)). On F8/F-keys, requires 'Use F1, F2 as standard function keys' enabled.")
        }
    }

    // MARK: - In-app hotkeys (NSEvent local monitor)

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            for action in HotkeyAction.allCases where action.scope == .inApp {
                guard let binding = self.bindings[action] else { continue }
                if event.matchesCarbonHotkey(keyCode: binding.keyCode, modifiers: binding.modifiers) {
                    NotificationCenter.default.post(name: action.notificationName, object: nil)
                    return nil   // consume
                }
            }
            return event
        }
    }

    // MARK: - Helpers (Carbon ↔ AppKit conversions)

    static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    static func symbols(forCarbonModifiers mods: UInt32) -> String {
        var s = ""
        if (mods & UInt32(controlKey)) != 0 { s += "⌃" }
        if (mods & UInt32(optionKey))  != 0 { s += "⌥" }
        if (mods & UInt32(shiftKey))   != 0 { s += "⇧" }
        if (mods & UInt32(cmdKey))     != 0 { s += "⌘" }
        return s
    }

    static func keyName(fromKeyCode keyCode: UInt32) -> String? {
        // Letters
        let letterMap: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        ]
        if let name = letterMap[keyCode] { return name }
        let digitMap: [UInt32: String] = [
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
        ]
        if let name = digitMap[keyCode] { return name }
        let punctMap: [UInt32: String] = [
            UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_Minus): "−",
            UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Comma): ",",
            UInt32(kVK_ANSI_Slash): "/",
            UInt32(kVK_ANSI_Semicolon): ";",
            UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_LeftBracket): "[",
            UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Grave): "`",
        ]
        if let name = punctMap[keyCode] { return name }
        let otherMap: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Escape): "Esc",
            UInt32(kVK_Return): "Return",
            UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Delete): "Delete",
            UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓",
        ]
        if let name = otherMap[keyCode] { return name }
        let functionMap: [UInt32: String] = [
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        return functionMap[keyCode]
    }

    private func fourCharCode(_ s: String) -> FourCharCode {
        let chars = s.utf8.prefix(4)
        var result: UInt32 = 0
        for c in chars { result = (result << 8) | UInt32(c) }
        return FourCharCode(result)
    }
}

// MARK: - Notification convenience

extension HotkeyManager {
    /// Shortcut for the action that the rest of the app cares about most.
    static var playPauseNotification: Notification.Name {
        HotkeyAction.globalPlayPause.notificationName
    }
}

// MARK: - NSEvent matching

extension NSEvent {
    func matchesCarbonHotkey(keyCode targetCode: UInt32, modifiers targetMods: UInt32) -> Bool {
        guard UInt32(self.keyCode) == targetCode else { return false }
        let active = modifierFlags.intersection([.command, .option, .shift, .control])
        return HotkeyManager.carbonFlags(from: active) == targetMods
    }
}
