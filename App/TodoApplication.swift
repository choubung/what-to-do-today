import AppKit
import SwiftUI

@main
@MainActor
enum TodoApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = TodoApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class TodoApplicationDelegate: NSObject, NSApplicationDelegate {
    private let model = TodoListModel()
    private var mainWindow: NSWindow?
    private var quickAddWindow: NSPanel?
    private var openedFromURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        // URL launch events arrive during startup. Defer the default window until they are handled.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.openedFromURL else { return }
            self.showMainWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "whattodotoday" {
            switch url.host {
            case "add":
                openedFromURL = true
                showQuickAdd()
            case "open":
                openedFromURL = true
                showMainWindow()
            default:
                break
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.refresh() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "What to Do Today"
            window.contentView = NSHostingView(rootView: TodoListView(model: model))
            window.minSize = NSSize(width: 360, height: 380)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("TodoMainWindow")
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showQuickAdd() {
        if let quickAddWindow, quickAddWindow.isVisible {
            quickAddWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        model.errorMessage = nil
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "새 할 일"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: QuickAddView(model: model) { [weak panel] in
            panel?.close()
        })
        panel.center()
        quickAddWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "What to Do Today 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem(title: "파일", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "파일")
        let addItem = NSMenuItem(title: "새 할 일", action: #selector(showQuickAdd), keyEquivalent: "n")
        addItem.target = self
        fileMenu.addItem(addItem)
        let listItem = NSMenuItem(title: "할 일 목록", action: #selector(showMainWindow), keyEquivalent: "1")
        listItem.target = self
        fileMenu.addItem(listItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "창 닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        let editItem = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "다시 실행", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
