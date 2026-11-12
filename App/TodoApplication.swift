import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if !STANDALONE
import WidgetKit
#endif

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
        application.setActivationPolicy(.regular)
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
                #if !STANDALONE
                WidgetCenter.shared.reloadAllTimelines()
                #endif
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
final class TodoApplicationDelegate: NSObject, NSApplicationDelegate {
    private let model = TodoListModel()
    private var mainWindow: NSWindow?
    private var quickAddWindow: NSPanel?
    private var openedFromURL = false
    private lazy var stickyNotes = StickyNoteCoordinator(model: model)
    private lazy var reminders = ReminderCoordinator(
        loadReminders: { [model] in try await model.loadPendingReminders() },
        markDelivered: { [model] generations, date in
            try await model.markRemindersDelivered(generations: generations, at: date)
        }
    )
    private var isPreparingToTerminate = false
    private var isTransferringData = false
    private var dayBoundaryTimer: Timer?
    private var trackedDayRange: DateInterval?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        _ = stickyNotes
        reminders.onOpenList = { [weak self] in self?.showMainWindow() }
        reminders.start()
        configureDateTracking()
        #if !STANDALONE
        WidgetCenter.shared.reloadTimelines(ofKind: "WhatToDoTodayWidget")
        #endif
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
        #if STANDALONE
        let scheme = "whattodotoday-dmg"
        #else
        let scheme = "whattodotoday"
        #endif
        for url in urls where url.scheme == scheme {
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
        #if STANDALONE
        _ = scheduleDayBoundary()
        #else
        let dayChanged = scheduleDayBoundary()
        #endif
        Task { await model.refresh() }
        #if !STANDALONE
        if dayChanged { WidgetCenter.shared.reloadTimelines(ofKind: "WhatToDoTodayWidget") }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if mainWindow?.isVisible != true || mainWindow?.isMiniaturized == true { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        reminders.stop()
        dayBoundaryTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTransferringData else { return .terminateCancel }
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
        #if !STANDALONE
        WidgetCenter.shared.reloadTimelines(ofKind: "WhatToDoTodayWidget")
        #endif
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
            window.setFrameAutosaveName("TodoMainWindow")
            window.center()
            mainWindow = window
        }
        if mainWindow?.isMiniaturized == true { mainWindow?.deminiaturize(nil) }
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

    @objc private func exportData() {
        guard !isTransferringData else { return }
        let panel = NSOpenPanel()
        panel.message = "할 일 백업을 저장할 폴더를 선택하세요."
        panel.prompt = "백업 저장"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        transferData(using: folder) {
            let backup = try await self.model.exportBackup(to: folder)
            self.showBackupResult(title: "백업을 저장했어요.", file: backup)
        }
    }

    @objc private func importData() {
        guard !isTransferringData else { return }
        let panel = NSOpenPanel()
        panel.message = "이 앱에서 내보낸 할 일 백업 파일을 선택하세요."
        panel.prompt = "백업 선택"
        if let backupType = UTType(filenameExtension: "wtdtbackup") {
            panel.allowedContentTypes = [backupType]
        }
        guard panel.runModal() == .OK, let file = panel.url else { return }

        let confirmation = NSAlert()
        confirmation.messageText = "백업의 할 일로 바꿀까요?"
        confirmation.informativeText = "이 앱의 할 일과 설정이 선택한 백업의 내용으로 바뀝니다. 현재 내용은 먼저 별도의 백업으로 저장됩니다."
        confirmation.addButton(withTitle: "취소")
        confirmation.addButton(withTitle: "백업 가져오기").hasDestructiveAction = true
        guard confirmation.runModal() == .alertSecondButtonReturn else { return }

        transferData(using: file) {
            let previous = try await self.model.restoreBackup(from: file)
            self.showBackupResult(title: "백업을 가져왔어요.", file: previous)
        }
    }

    private func transferData(using url: URL, operation: @escaping @MainActor () async throws -> Void) {
        isTransferringData = true
        let hasAccess = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                isTransferringData = false
            }
            do {
                await stickyNotes.flushPositions()
                try await operation()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    private func showBackupResult(title: String, file: URL) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "저장된 백업: \(file.lastPathComponent)"
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "Finder에서 보기")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
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
        let exportItem = fileMenu.addItem(withTitle: "할 일 백업 내보내기…", action: #selector(exportData), keyEquivalent: "")
        exportItem.target = self
        let importItem = fileMenu.addItem(withTitle: "할 일 백업 가져오기…", action: #selector(importData), keyEquivalent: "")
        importItem.target = self
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
