import AppKit
import Combine
import SwiftUI

@MainActor
final class StickyNoteCoordinator: NSObject {
    private let model: TodoListModel
    private var windows: [UUID: StickyNoteWindowController] = [:]
    private var snapshotSubscription: AnyCancellable?
    private var pendingPositions: [UUID: StickyNotePosition] = [:]
    // Covers an immediate hide/show while the last position write is still in flight.
    private var lastKnownPositions: [UUID: StickyNotePosition] = [:]
    private var positionDebounce: Task<Void, Never>?
    private var positionWrites: Task<Void, Never>?
    private var writeGeneration = 0
    private var nextCascadeIndex = 0

    init(model: TodoListModel) {
        self.model = model
        super.init()
        snapshotSubscription = model.$snapshot.sink { [weak self] snapshot in
            self?.reconcile(snapshot)
        }
        model.onShowStickyNotes = { [weak self] ids in self?.bringForward(ids) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Includes writes already submitted to the repository, so quitting cannot discard a final drag.
    func flushPositions() async {
        positionDebounce?.cancel()
        positionDebounce = nil
        enqueuePositionWrites()
        await positionWrites?.value
    }

    private func reconcile(_ snapshot: TodoSnapshot) {
        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        lastKnownPositions = lastKnownPositions.filter { tasks[$0.key] != nil }
        let shownNotes = snapshot.stickyNotes.filter { $0.isVisible && tasks[$0.id]?.isCompleted == false }
        let shownIDs = Set(shownNotes.map(\.id))

        for id in Array(windows.keys) where !shownIDs.contains(id) {
            guard let controller = windows.removeValue(forKey: id) else { continue }
            if tasks[id] != nil {
                pendingPositions[id] = controller.currentPosition
                lastKnownPositions[id] = controller.currentPosition
            } else {
                pendingPositions.removeValue(forKey: id)
            }
            controller.discard()
        }
        // Hiding a window flushes its final position instead of waiting for a drag timer.
        enqueuePositionWrites()

        let screens = currentScreens()
        for note in shownNotes {
            guard let task = tasks[note.id] else { continue }
            if let controller = windows[note.id] {
                controller.update(task: task, note: note)
                continue
            }
            let controller = StickyNoteWindowController(model: model, task: task, note: note)
            let savedPosition = lastKnownPositions[note.id] ?? note.position
            guard let placement = StickyNoteLayout.placement(
                savedOrigin: savedPosition.map { CGPoint(x: $0.x, y: $0.y) },
                displayID: savedPosition?.displayID,
                size: controller.preferredFrameSize,
                cascadeIndex: nextCascadeIndex,
                screens: screens
            ) else {
                controller.discard()
                continue
            }
            nextCascadeIndex = (nextCascadeIndex + 1) % 8
            controller.move(to: placement)
            controller.onMove = { [weak self] position in self?.schedulePosition(position, for: note.id) }
            controller.onHide = { [weak self] in self?.hide(note.id) }
            windows[note.id] = controller
            controller.show()
            if note.position != controller.currentPosition {
                schedulePosition(controller.currentPosition, for: note.id)
            }
        }
    }

    private func bringForward(_ ids: [UUID]) {
        for id in ids { windows[id]?.bringForward() }
    }

    private func hide(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            await flushPositions()
            _ = await model.hideStickyNotes([id])
        }
    }

    private func schedulePosition(_ position: StickyNotePosition, for id: UUID) {
        pendingPositions[id] = position
        lastKnownPositions[id] = position
        positionDebounce?.cancel()
        positionDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            positionDebounce = nil
            await flushPositions()
        }
    }

    private func enqueuePositionWrites() {
        guard !pendingPositions.isEmpty else { return }
        let positions = pendingPositions
        pendingPositions.removeAll()
        let precedingWrite = positionWrites
        writeGeneration += 1
        let generation = writeGeneration
        let model = model
        positionWrites = Task { [weak self] in
            await precedingWrite?.value
            for (id, position) in positions {
                await model.saveStickyPosition(id: id, position: position)
            }
            if let self, writeGeneration == generation { positionWrites = nil }
        }
    }

    @objc private func screenConfigurationChanged() {
        let screens = currentScreens()
        guard !screens.isEmpty else { return }
        for (id, controller) in windows {
            let position = controller.currentPosition
            guard let placement = StickyNoteLayout.placement(
                savedOrigin: CGPoint(x: position.x, y: position.y),
                displayID: position.displayID,
                size: controller.preferredFrameSize,
                screens: screens
            ) else { continue }
            controller.move(to: placement)
            schedulePosition(controller.currentPosition, for: id)
        }
        // A display can become available after launch had no valid screen yet.
        reconcile(model.snapshot)
    }

    private func currentScreens() -> [StickyNoteLayout.Screen] {
        let primary = NSScreen.main ?? NSScreen.screens.first
        return NSScreen.screens.map { screen in
            StickyNoteLayout.Screen(
                id: StickyNoteWindowController.displayID(for: screen),
                visibleFrame: screen.visibleFrame,
                isPrimary: screen === primary
            )
        }
    }
}

@MainActor
private final class StickyNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class StickyNoteWindowController: NSWindowController, NSWindowDelegate {
    private let model: TodoListModel
    private var task: TodoItem
    private var note: StickyNoteState
    private var suppressMove = false
    private var placementDisplayID: String?
    private var hostingView: NSHostingView<StickyNoteView>?
    private var isRegisteredInWindowMenu = false
    let preferredFrameSize: CGSize
    var onMove: ((StickyNotePosition) -> Void)?
    var onHide: (() -> Void)?

    var currentPosition: StickyNotePosition {
        let frame = window?.frame ?? .zero
        return StickyNotePosition(
            x: Double(frame.origin.x), y: Double(frame.origin.y),
            displayID: window?.screen.map(Self.displayID) ?? placementDisplayID
        )
    }

    init(model: TodoListModel, task: TodoItem, note: StickyNoteState) {
        self.model = model
        self.task = task
        self.note = note
        let panel = StickyNotePanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 168),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        preferredFrameSize = panel.frame.size
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isExcludedFromWindowsMenu = false
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.delegate = self
        update(task: task, note: note)
    }

    required init?(coder: NSCoder) { nil }

    func update(task: TodoItem, note: StickyNoteState) {
        let contentChanged = self.task != task || self.note.isAlwaysOnTop != note.isAlwaysOnTop
        let behaviorChanged = hostingView == nil || self.note.isAlwaysOnTop != note.isAlwaysOnTop
        self.task = task
        self.note = note
        guard let panel = window as? NSPanel else { return }
        if panel.title != task.title {
            panel.title = task.title
            if isRegisteredInWindowMenu {
                NSApp.changeWindowsItem(panel, title: task.title, filename: false)
            }
        }
        if behaviorChanged {
            panel.isFloatingPanel = note.isAlwaysOnTop
            panel.level = note.isAlwaysOnTop ? .floating : .normal
            panel.collectionBehavior = note.isAlwaysOnTop
                ? [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .participatesInCycle]
                : [.managed, .fullScreenNone, .participatesInCycle]
        }
        guard hostingView == nil || contentChanged else { return }
        let content = StickyNoteView(
            model: model, task: task, note: note,
            onHide: { [weak self] in self?.onHide?() }
        )
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hostingView = NSHostingView(rootView: content)
            self.hostingView = hostingView
            panel.contentView = hostingView
        }
    }

    func show() {
        guard let window else { return }
        window.orderFront(nil)
        // NSPanel does not reliably add itself to the standard Window menu.
        NSApp.addWindowsItem(window, title: task.title, filename: false)
        isRegisteredInWindowMenu = true
    }

    func bringForward() { window?.makeKeyAndOrderFront(nil) }

    func move(to placement: StickyNoteLayout.Placement) {
        suppressMove = true
        placementDisplayID = placement.displayID
        window?.setFrame(placement.frame, display: true)
        suppressMove = false
    }

    func discard() {
        onMove = nil
        onHide = nil
        if let window { NSApp.removeWindowsItem(window) }
        isRegisteredInWindowMenu = false
        window?.delegate = nil
        window?.contentView = nil
        hostingView = nil
        close()
    }

    func windowDidMove(_ notification: Notification) {
        guard !suppressMove else { return }
        onMove?(currentPosition)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onHide?()
        return false
    }

    static func displayID(for screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
            ?? screen.localizedName
    }
}
