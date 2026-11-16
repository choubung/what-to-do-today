import AppKit
import Carbon
import Combine

enum ShortcutAction: String, CaseIterable, Identifiable {
    case newTask, restoreNotes, hideNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTask: "새 할 일"
        case .restoreNotes: "포스트잇 그대로 띄우기"
        case .hideNotes: "포스트잇 모두 숨기기"
        }
    }

    var defaultShortcut: AppShortcut {
        let code: UInt32 = switch self {
        case .newTask: 45
        case .restoreNotes: 1
        case .hideNotes: 4
        }
        return AppShortcut(keyCode: code, modifiers: UInt32(controlKey | optionKey))
    }
}

struct AppShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard isValid else { return nil }
    }

    var isValid: Bool {
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        guard modifiers & ~allowed == 0,
              modifiers & UInt32(controlKey | optionKey | cmdKey) != 0,
              Self.keyNames[keyCode] != nil else { return false }
        // These are already menu commands in this app. A global registration
        // would intercept them before the focused editor can handle the command.
        let localKeys: Set<UInt32> = [0, 6, 7, 8, 9, 12, 13, 18, 43, 45, 46]
        if modifiers == UInt32(cmdKey), localKeys.contains(keyCode) { return false }
        return !(modifiers == UInt32(cmdKey | shiftKey) && keyCode == 6)
    }

    var displayText: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    private var keyLabel: String {
        guard Self.printableKeys.contains(keyCode),
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return Self.keyNames[keyCode] ?? "?"
        }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return Self.keyNames[keyCode] ?? "?" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let result = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeyState, characters.count, &length, &characters)
        guard result == noErr, length > 0 else { return Self.keyNames[keyCode] ?? "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let printableKeys: Set<UInt32> = Set(0...50).subtracting([36, 48, 49])
    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "−", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "↖", 116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2",
        121: "⇟", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}

@MainActor
final class GlobalShortcuts: ObservableObject {
    static let shared = GlobalShortcuts()

    @Published private(set) var shortcuts: [ShortcutAction: AppShortcut] = [:]
    @Published private(set) var errors: [ShortcutAction: String] = [:]
    var onAction: ((ShortcutAction) -> Void)?
    var onChange: (() -> Void)?

    private struct StoredShortcut: Codable { let shortcut: AppShortcut? }
    private struct Registration {
        let id: UInt32
        let reference: EventHotKeyRef
    }
    private let defaults: UserDefaults
    private let settingsKey = "globalShortcuts.v1"
    private let signature: OSType = 0x57544454 // WTDT
    private var registrations: [ShortcutAction: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var pressedIDs: Set<UInt32> = []
    private var isStarted = false
    private var isSuspended = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: settingsKey).flatMap {
            try? JSONDecoder().decode([String: StoredShortcut].self, from: $0)
        } ?? [:]
        for action in ShortcutAction.allCases {
            if let entry = saved[action.rawValue] {
                if let shortcut = entry.shortcut, shortcut.isValid { shortcuts[action] = shortcut }
            } else {
                shortcuts[action] = action.defaultShortcut
            }
        }
    }

    func start() {
        guard !isStarted else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            // The handler is installed on AppKit's application event target and
            // receives keyboard events on the main run loop.
            return MainActor.assumeIsolated {
                Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue().handle(event)
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            for action in ShortcutAction.allCases where shortcuts[action] != nil {
                errors[action] = "단축키를 시작하지 못했어요. 앱을 다시 실행해 주세요."
            }
            onChange?()
            return
        }
        isStarted = true
        registerConfiguredShortcuts()
    }

    func stop() {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        isStarted = false
        isSuspended = false
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        unregisterAll()
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if isStarted { registerConfiguredShortcuts() }
    }

    func registeredShortcut(for action: ShortcutAction) -> AppShortcut? {
        registrations[action] == nil ? nil : shortcuts[action]
    }

    @discardableResult
    func setShortcut(_ shortcut: AppShortcut?, for action: ShortcutAction) -> Bool {
        if let shortcut {
            guard shortcut.isValid else {
                errors[action] = "다른 키 조합을 선택해 주세요. Control, Option 또는 Command를 함께 눌러 주세요."
                return false
            }
            guard !shortcuts.contains(where: { $0.key != action && $0.value == shortcut }) else {
                errors[action] = "다른 기능에서 사용 중인 단축키예요."
                return false
            }
            if shortcuts[action] == shortcut, registrations[action] != nil {
                errors[action] = nil
                return true
            }
            guard let replacement = register(shortcut, for: action) else { return false }
            unregister(action)
            if isStarted && !isSuspended {
                registrations[action] = replacement
            } else {
                UnregisterEventHotKey(replacement.reference)
            }
        } else {
            unregister(action)
        }
        shortcuts[action] = shortcut
        errors[action] = nil
        let saved = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map {
            ($0.rawValue, StoredShortcut(shortcut: shortcuts[$0]))
        })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: settingsKey) }
        onChange?()
        return true
    }

    private func registerConfiguredShortcuts() {
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action] else { continue }
            registrations[action] = register(shortcut, for: action)
        }
        onChange?()
    }

    private func register(_ shortcut: AppShortcut, for action: ShortcutAction) -> Registration? {
        guard !isSystemShortcut(shortcut) else {
            errors[action] = "macOS에서 사용 중인 단축키예요. 다른 조합을 선택해 주세요."
            return nil
        }
        let id = nextID
        nextID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                        EventHotKeyID(signature: signature, id: id),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            errors[action] = "다른 앱에서 사용 중이거나 등록할 수 없는 단축키예요."
            return nil
        }
        errors[action] = nil
        return Registration(id: id, reference: reference)
    }

    private func isSystemShortcut(_ shortcut: AppShortcut) -> Bool {
        var keys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&keys) == noErr,
              let entries = keys?.takeRetainedValue() as? [[String: Any]] else { return false }
        return entries.contains {
            ($0[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true
                && ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == shortcut.keyCode
                && ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == shortcut.modifiers
        }
    }

    private func unregister(_ action: ShortcutAction) {
        guard let registration = registrations.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(registration.reference)
        pressedIDs.remove(registration.id)
    }

    private func unregisterAll() {
        for action in Array(registrations.keys) { unregister(action) }
        pressedIDs.removeAll()
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKey = EventHotKeyID()
        let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
        guard result == noErr, hotKey.signature == signature,
              let action = registrations.first(where: { $0.value.id == hotKey.id })?.key else {
            return OSStatus(eventNotHandledErr)
        }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            pressedIDs.remove(hotKey.id)
        } else if !isSuspended, pressedIDs.insert(hotKey.id).inserted {
            onAction?(action)
        }
        return noErr
    }
}
