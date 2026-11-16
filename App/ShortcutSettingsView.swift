import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject private var shortcuts = GlobalShortcuts.shared
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        GroupBox("단축키") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(action.title)
                            Spacer()
                            Button {
                                recorder.begin(action)
                            } label: {
                                Text(recorder.action == action
                                     ? "키 조합 입력…"
                                     : shortcuts.shortcuts[action]?.displayText ?? "없음")
                                    .monospaced()
                                    .frame(width: 100)
                            }
                            .accessibilityLabel("\(action.title) 단축키 변경")
                            .accessibilityValue(shortcuts.shortcuts[action]?.displayText ?? "없음")
                            Button {
                                recorder.end()
                                _ = shortcuts.setShortcut(nil, for: action)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("단축키 해제")
                            .accessibilityLabel("\(action.title) 단축키 해제")
                            .disabled(shortcuts.shortcuts[action] == nil)
                        }
                        if let error = recorder.action == action ? recorder.error : nil {
                            Text(error).font(.caption).foregroundStyle(.red)
                        } else if let error = shortcuts.errors[action] {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                if recorder.action != nil {
                    Text("Control, Option 또는 Command와 함께 누르세요. Esc로 취소합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("앱이 실행 중이면 다른 앱을 사용하는 중에도 동작합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
        .onDisappear { recorder.end() }
    }
}

/// The monitor exists only while recording and consumes events from the settings
/// window before its menu shortcuts or text fields can handle them.
@MainActor
private final class ShortcutRecorder: ObservableObject {
    @Published private(set) var action: ShortcutAction?
    @Published private(set) var error: String?
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func begin(_ action: ShortcutAction) {
        end()
        guard let window = NSApp.keyWindow else { return }
        self.window = window
        self.action = action
        GlobalShortcuts.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            }
        ]
    }

    func end() {
        guard action != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window = nil
        action = nil
        error = nil
        GlobalShortcuts.shared.resume()
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let action else { return false }
        guard event.type == .keyDown, event.window === window else {
            end()
            return false
        }
        guard !event.isARepeat else { return true }
        if event.keyCode == 53 {
            end()
            return true
        }
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        if (event.keyCode == 51 || event.keyCode == 117) && modifiers.isEmpty {
            _ = GlobalShortcuts.shared.setShortcut(nil, for: action)
            end()
            return true
        }
        guard let shortcut = AppShortcut(event: event) else {
            error = "다른 키 조합을 선택해 주세요. Control, Option 또는 Command가 필요합니다."
            return true
        }
        error = nil
        if GlobalShortcuts.shared.setShortcut(shortcut, for: action) { end() }
        return true
    }
}
