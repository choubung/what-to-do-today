import AppKit
import Carbon
import Foundation

@main
private enum GlobalShortcutTests {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let suite = "what-to-do-today-shortcuts-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = GlobalShortcuts(defaults: defaults)
        defer { shortcuts.stop() }

        precondition(shortcuts.shortcuts[.newTask] == ShortcutAction.newTask.defaultShortcut)
        precondition(shortcuts.shortcuts[.restoreNotes] == ShortcutAction.restoreNotes.defaultShortcut)
        precondition(shortcuts.shortcuts[.hideNotes] == ShortcutAction.hideNotes.defaultShortcut)
        precondition(!AppShortcut(keyCode: 45, modifiers: 0).isValid)
        precondition(!AppShortcut(keyCode: 45, modifiers: UInt32(shiftKey)).isValid)
        precondition(!AppShortcut(keyCode: 45, modifiers: UInt32(cmdKey)).isValid)
        precondition(!AppShortcut(keyCode: 12, modifiers: UInt32(cmdKey)).isValid)
        precondition(!AppShortcut(keyCode: 55, modifiers: UInt32(controlKey)).isValid)

        // Disable defaults so this test does not claim the user's normal bindings.
        for action in ShortcutAction.allCases { precondition(shortcuts.setShortcut(nil, for: action)) }
        let reopened = GlobalShortcuts(defaults: defaults)
        precondition(reopened.shortcuts.isEmpty, "Disabled shortcuts must remain disabled after reopening")

        let first = AppShortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | cmdKey))
        let second = AppShortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | cmdKey))
        precondition(shortcuts.setShortcut(first, for: .newTask))
        precondition(!shortcuts.setShortcut(first, for: .hideNotes), "Two actions cannot use the same shortcut")
        precondition(shortcuts.shortcuts[.hideNotes] == nil)
        precondition(shortcuts.errors[.hideNotes] != nil)
        shortcuts.start()
        precondition(shortcuts.registeredShortcut(for: .newTask) == first)
        shortcuts.suspend()
        precondition(shortcuts.registeredShortcut(for: .newTask) == nil)
        precondition(shortcuts.setShortcut(second, for: .newTask))
        shortcuts.resume()
        precondition(shortcuts.registeredShortcut(for: .newTask) == second)

        let competingSuite = suite + ".competing"
        let competingDefaults = UserDefaults(suiteName: competingSuite)!
        defer { competingDefaults.removePersistentDomain(forName: competingSuite) }
        let competing = GlobalShortcuts(defaults: competingDefaults)
        defer { competing.stop() }
        for action in ShortcutAction.allCases { precondition(competing.setShortcut(nil, for: action)) }
        precondition(competing.setShortcut(first, for: .newTask))
        competing.start()
        precondition(!shortcuts.setShortcut(first, for: .newTask), "An existing exclusive registration must reject the change")
        precondition(shortcuts.registeredShortcut(for: .newTask) == second, "A failed change must preserve the active old shortcut")
        precondition(shortcuts.shortcuts[.newTask] == second)
        precondition(GlobalShortcuts(defaults: defaults).shortcuts[.newTask] == second, "A failed change must preserve the saved shortcut")

        shortcuts.suspend()
        precondition(!shortcuts.setShortcut(first, for: .newTask), "Recording must still check OS conflicts while suspended")
        shortcuts.resume()
        precondition(shortcuts.registeredShortcut(for: .newTask) == second)
        precondition(shortcuts.setShortcut(nil, for: .newTask))
        precondition(shortcuts.registeredShortcut(for: .newTask) == nil)
        precondition(shortcuts.errors[.newTask] == nil)
        precondition(GlobalShortcuts(defaults: defaults).shortcuts[.newTask] == nil)
        print("Passed global shortcut validation, persistence, replacement, conflict rollback, suspension, and unregister tests.")
    }
}
