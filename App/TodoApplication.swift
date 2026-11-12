import AppKit
import SwiftUI
import WidgetKit

@main
@MainActor
enum TodoApplication {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--mcp" {
            runMCPServer()
            return
        }
        let application = NSApplication.shared
        let delegate = TodoApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func runMCPServer() {
        var server = TodoMCPServer(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            openStore: TodoStore.live,
            didChangeStore: {
                DistributedNotificationCenter.default().postNotificationName(
                    TodoStore.notificationName, object: nil, userInfo: nil, deliverImmediately: true
                )
                WidgetCenter.shared.reloadAllTimelines()
            }
        )
        do {
            try server.run()
        } catch {
            FileHandle.standardError.write(Data("MCP 연결을 종료합니다.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}

@MainActor
final class TodoApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    private let model = TodoListModel()
    private var mainWindow: NSWindow?
    private var quickAddWindow: NSPanel?
    private var statusItem: NSStatusItem?
    private var statusPanel: TodoStatusPanel?
    private var openedFromURL = false
    private lazy var stickyNotes = StickyNoteCoordinator(model: model)
    private lazy var reminders = ReminderCoordinator(
        loadReminders: { [model] in try await model.loadPendingReminders() },
        markDelivered: { [model] generations, date in
            try await model.markRemindersDelivered(generations: generations, at: date)
        }
    )
    private var isPreparingToTerminate = false
    private var dayBoundaryTimer: Timer?
    private var trackedDayRange: DateInterval?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureStatusItem()
        _ = stickyNotes
        reminders.onOpenList = { [weak self] in self?.showMainWindow() }
        reminders.start()
        configureDateTracking()
        WidgetCenter.shared.reloadTimelines(ofKind: "WhatToDoTodayWidget")
        // Normal open/reopen events show the list; a login launch only restores background services.
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !openedFromURL && !ReminderLaunchPolicy.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent)
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !ReminderLaunchPolicy.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent) else { return false }
        showMainWindow()
        return true
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
        let dayChanged = scheduleDayBoundary()
        Task { await model.refresh() }
        if dayChanged { WidgetCenter.shared.reloadTimelines(ofKind: "WhatToDoTodayWidget") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow?.isVisible != true || mainWindow?.isMiniaturized == true { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        // AppKit sends this before updating the window's visibility.
        DispatchQueue.main.async { [weak self] in
            guard let self, !isPreparingToTerminate else { return }
            let hasEditor = [mainWindow, quickAddWindow].contains {
                $0?.isVisible == true || $0?.isMiniaturized == true
            }
            if !hasEditor { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow, panel === statusPanel else { return }
        statusItem?.expandedInterfaceSession?.cancel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        reminders.stop()
        dayBoundaryTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate else { return .terminateLater }
        isPreparingToTerminate = true
        Task {
            await reminders.finishAndStop()
            await model.waitForPendingSave()
            await stickyNotes.flushPositions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func hideAllStickyNotes() {
        Task { _ = await model.hideAllStickyNotes() }
    }

    private func restoreHiddenStickyNotes() {
        Task { _ = await model.restoreHiddenStickyNotes() }
    }

    @objc private func closeKeyWindow(_ sender: Any?) {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.performClose(sender)
    }

    private func configureDateTracking() {
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(localTimeChanged(_:)), name: name, object: nil
            )
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(localTimeChanged(_:)), name: NSWorkspace.didWakeNotification, object: nil
        )
        _ = scheduleDayBoundary()
    }

    @objc private nonisolated func localTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.refreshForLocalTimeChange() }
    }

    private func refreshForLocalTimeChange() {
        guard !isPreparingToTerminate else { return }
        _ = scheduleDayBoundary()
        Task { await model.refresh() }
        WidgetCenter.shared.reloadTimelines(ofKind: "WhatToDoTodayWidget")
    }

    /// Uses the actual local day's end, including days shortened or lengthened by clock changes.
    @discardableResult
    private func scheduleDayBoundary() -> Bool {
        dayBoundaryTimer?.invalidate()
        dayBoundaryTimer = nil
        let dayRange = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: Date())
        let changed = dayRange != trackedDayRange
        trackedDayRange = dayRange
        guard let dayRange else { return changed }

        let timer = Timer(fire: dayRange.end, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshForLocalTimeChange() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dayBoundaryTimer = timer
        return changed
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "What to Do Today"
            window.contentView = NSHostingView(rootView: TodoListView(model: model, reminders: reminders))
            window.minSize = NSSize(width: 360, height: 380)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("TodoMainWindow")
            window.center()
            mainWindow = window
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showQuickAdd() {
        NSApp.setActivationPolicy(.regular)
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
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickAddView(model: model) { [weak panel] in
            panel?.close()
        })
        panel.center()
        quickAddWindow = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "What to Do Today")
        item.button?.toolTip = "What to Do Today"
        item.expandedInterfaceDelegate = self
        statusItem = item
    }

    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        guard let button = statusItem.button, let buttonWindow = button.window, let screen = buttonWindow.screen else {
            session.cancel()
            return
        }
        let panel = TodoStatusPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .popUpMenu
        // The menu belongs on the Space where its icon was clicked, even when
        // a different application owns that full-screen Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .ignoresCycle]
        panel.delegate = self
        panel.onCancel = { [weak session] in session?.cancel() }

        let content = NSHostingView(rootView: VStack(alignment: .leading, spacing: 3) {
            statusAction("할 일 목록 열기", icon: "checklist", action: showMainWindow)
            statusAction("새 할 일", icon: "plus", action: showQuickAdd)
            statusAction("포스트잇 모두 숨기기", icon: "eye.slash", action: hideAllStickyNotes)
                .disabled(model.visibleStickyCount == 0 || model.isSaving)
            statusAction("포스트잇 그대로 띄우기", icon: "eye", action: restoreHiddenStickyNotes)
                .disabled(!model.canRestoreStickyNotes || model.isSaving)
            Divider().padding(.vertical, 3)
            statusAction("What to Do Today 종료", icon: "power") { NSApp.terminate(nil) }
        }
        .padding(8)
        .frame(width: 225)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .allowsWindowActivationEvents())
        panel.contentView = content
        let size = content.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let x = min(max(anchor.minX, screen.frame.minX + 4), screen.frame.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 4, width: size.width, height: size.height), display: false)
        statusPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        let panel = statusPanel
        statusPanel = nil
        panel?.delegate = nil
        panel?.close()
    }

    private func statusAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            self.statusItem?.expandedInterfaceSession?.cancel()
            action()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "What to Do Today 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
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
        let hideNotesItem = NSMenuItem(title: "포스트잇 모두 숨기기", action: #selector(hideAllStickyNotes), keyEquivalent: "")
        hideNotesItem.target = self
        fileMenu.addItem(hideNotesItem)
        fileMenu.addItem(.separator())
        let closeItem = fileMenu.addItem(withTitle: "창 닫기", action: #selector(closeKeyWindow(_:)), keyEquivalent: "w")
        closeItem.target = self
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

        let windowItem = NSMenuItem(title: "윈도우", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "확대/축소", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "모두 앞으로 가져오기", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }
}

private final class TodoStatusPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
