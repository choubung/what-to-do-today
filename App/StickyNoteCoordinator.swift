import AppKit
import Combine
import SwiftUI

private struct StickyNoteGeometry: Equatable {
    let position: StickyNotePosition
    let size: StickyNoteSize
}

@MainActor
final class StickyNoteCoordinator: NSObject {
    private let model: TodoListModel
    private let completionFeedback = CompletionFeedbackController()
    private var windows: [UUID: StickyNoteWindowController] = [:]
    private var snapshotSubscription: AnyCancellable?
    private var pendingGeometry: [UUID: StickyNoteGeometry] = [:]
    // Covers an immediate hide/show while a final drag or resize write is still in flight.
    private var lastKnownGeometry: [UUID: StickyNoteGeometry] = [:]
    private var geometryDebounce: Task<Void, Never>?
    private var geometryWrites: Task<Void, Never>?
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

    /// Includes submitted writes, so quitting cannot discard a final drag or resize.
    func flushPositions() async {
        geometryDebounce?.cancel()
        geometryDebounce = nil
        enqueueGeometryWrites()
        await geometryWrites?.value
    }

    private func reconcile(_ snapshot: TodoSnapshot) {
        let tasks = Dictionary(uniqueKeysWithValues: snapshot.tasks.map { ($0.id, $0) })
        lastKnownGeometry = lastKnownGeometry.filter { tasks[$0.key] != nil }
        let shownNotes = snapshot.stickyNotes.filter { $0.isVisible && tasks[$0.id]?.isCompleted == false }
        let shownIDs = Set(shownNotes.map(\.id))

        for id in Array(windows.keys) where !shownIDs.contains(id) {
            guard let controller = windows.removeValue(forKey: id) else { continue }
            if tasks[id] != nil {
                pendingGeometry[id] = controller.currentGeometry
                lastKnownGeometry[id] = controller.currentGeometry
            } else {
                pendingGeometry.removeValue(forKey: id)
            }
            controller.discard()
        }
        // Hiding flushes final geometry instead of waiting for the drag/resize timer.
        enqueueGeometryWrites()

        let screens = currentScreens()
        for note in shownNotes {
            guard let task = tasks[note.id] else { continue }
            if let controller = windows[note.id] {
                controller.update(task: task, note: note)
                continue
            }
            let controller = StickyNoteWindowController(model: model, task: task, note: note)
            let savedPosition = lastKnownGeometry[note.id]?.position ?? note.position
            let savedSize = lastKnownGeometry[note.id]?.size ?? note.size
            guard let placement = StickyNoteLayout.placement(
                savedOrigin: savedPosition.map { CGPoint(x: $0.x, y: $0.y) },
                displayID: savedPosition?.displayID,
                size: savedSize.map { CGSize(width: $0.width, height: $0.height) }
                    ?? StickyNoteLayout.defaultSize,
                cascadeIndex: nextCascadeIndex,
                screens: screens
            ) else {
                controller.discard()
                continue
            }
            nextCascadeIndex = (nextCascadeIndex + 1) % 8
            controller.move(to: placement)
            controller.onGeometryChange = { [weak self] geometry in
                self?.scheduleGeometry(geometry, for: note.id)
            }
            controller.onHide = { [weak self] in self?.hide(note.id) }
            controller.onComplete = { [weak self] task in self?.complete(task) }
            windows[note.id] = controller
            controller.show()
            let geometry = controller.currentGeometry
            if note.position != geometry.position || note.size != geometry.size {
                scheduleGeometry(geometry, for: note.id)
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

    private func complete(_ task: TodoItem) {
        // A successful save removes the sticky window during snapshot reconciliation.
        guard let frame = windows[task.id]?.window?.frame else { return }
        Task { [weak self] in
            guard let self else { return }
            if await model.setCompleted(task, completed: true) {
                completionFeedback.show(near: frame)
            }
        }
    }

    private func scheduleGeometry(_ geometry: StickyNoteGeometry, for id: UUID) {
        pendingGeometry[id] = geometry
        lastKnownGeometry[id] = geometry
        geometryDebounce?.cancel()
        geometryDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            geometryDebounce = nil
            await flushPositions()
        }
    }

    private func enqueueGeometryWrites() {
        guard !pendingGeometry.isEmpty else { return }
        let geometries = pendingGeometry
        pendingGeometry.removeAll()
        let precedingWrite = geometryWrites
        writeGeneration += 1
        let generation = writeGeneration
        let model = model
        geometryWrites = Task { [weak self] in
            await precedingWrite?.value
            for (id, geometry) in geometries {
                await model.saveStickyPosition(id: id, position: geometry.position)
                await model.saveStickySize(id: id, size: geometry.size)
            }
            if let self, writeGeneration == generation { geometryWrites = nil }
        }
    }

    @objc private func screenConfigurationChanged() {
        let screens = currentScreens()
        guard !screens.isEmpty else { return }
        for (id, controller) in windows {
            let geometry = controller.currentGeometry
            let position = geometry.position
            guard let placement = StickyNoteLayout.placement(
                savedOrigin: CGPoint(x: position.x, y: position.y),
                displayID: position.displayID,
                size: CGSize(width: geometry.size.width, height: geometry.size.height),
                screens: screens
            ) else { continue }
            controller.move(to: placement)
            scheduleGeometry(controller.currentGeometry, for: id)
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

    override func performClose(_ sender: Any?) {
        // The native action can ignore a hidden close button. Keep menu/keyboard
        // closing on the same persisted hide path as the note's custom button.
        guard delegate?.windowShouldClose?(self) ?? true else { return }
        close()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSWindow.performClose(_:)) { return isVisible }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        // Native validation also checks the standard button, which this panel hides.
        if item.action == #selector(NSWindow.performClose(_:)) { return isVisible }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
private final class StickyNoteHostingView: NSHostingView<StickyNoteView> {
    // A nonactivating panel must opt in to both the first click and key focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class StickyNoteWindowController: NSWindowController, NSWindowDelegate {
    private let model: TodoListModel
    private var task: TodoItem
    private var note: StickyNoteState
    private var suppressGeometryChanges = false
    private var placementDisplayID: String?
    private var hostingView: StickyNoteHostingView?
    private var isRegisteredInWindowMenu = false
    var onGeometryChange: ((StickyNoteGeometry) -> Void)?
    var onHide: (() -> Void)?
    var onComplete: ((TodoItem) -> Void)?

    var currentGeometry: StickyNoteGeometry {
        let frame = window?.frame ?? .zero
        return StickyNoteGeometry(
            position: StickyNotePosition(
                x: Double(frame.origin.x), y: Double(frame.origin.y),
                displayID: window?.screen.map(Self.displayID) ?? placementDisplayID
            ),
            size: StickyNoteSize(width: Double(frame.width), height: Double(frame.height))
        )
    }

    init(model: TodoListModel, task: TodoItem, note: StickyNoteState) {
        self.model = model
        self.task = task
        self.note = note
        let panel = StickyNotePanel(
            contentRect: NSRect(origin: .zero, size: StickyNoteLayout.defaultSize),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isExcludedFromWindowsMenu = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = StickyNoteAppearance.background(for: note.effectiveColorHex)
        panel.minSize = StickyNoteLayout.minimumSize
        panel.tabbingMode = .disallowed
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.delegate = self
        update(task: task, note: note)
    }

    required init?(coder: NSCoder) { nil }

    func update(task: TodoItem, note: StickyNoteState) {
        let contentChanged = self.task != task
            || self.note.isAlwaysOnTop != note.isAlwaysOnTop
            || self.note.fontSize != note.fontSize
            || self.note.colorHex != note.colorHex
            || self.note.categoryColorHex != note.categoryColorHex
        let behaviorChanged = hostingView == nil || self.note.isAlwaysOnTop != note.isAlwaysOnTop
        self.task = task
        self.note = note
        guard let panel = window as? NSPanel else { return }
        panel.backgroundColor = StickyNoteAppearance.background(for: note.effectiveColorHex)
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
            onHide: { [weak self] in self?.onHide?() },
            onComplete: { [weak self] in self?.onComplete?(task) }
        )
        if let hostingView {
            hostingView.rootView = content
        } else {
            let hostingView = StickyNoteHostingView(rootView: content)
            // Keep the custom drag strip in the transparent titlebar and let native
            // edge resizing determine the frame instead of the text's ideal size.
            hostingView.safeAreaRegions = []
            hostingView.sizingOptions = []
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
        suppressGeometryChanges = true
        placementDisplayID = placement.displayID
        // A newly connected display may be smaller than the normal minimum.
        window?.minSize = CGSize(
            width: min(StickyNoteLayout.minimumSize.width, placement.frame.width),
            height: min(StickyNoteLayout.minimumSize.height, placement.frame.height)
        )
        window?.setFrame(placement.frame, display: true)
        suppressGeometryChanges = false
    }

    func discard() {
        onGeometryChange = nil
        onHide = nil
        onComplete = nil
        if let window { NSApp.removeWindowsItem(window) }
        isRegisteredInWindowMenu = false
        window?.delegate = nil
        window?.contentView = nil
        hostingView = nil
        close()
    }

    func windowDidMove(_ notification: Notification) {
        geometryDidChange()
    }

    func windowDidResize(_ notification: Notification) {
        geometryDidChange()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        geometryDidChange()
    }

    private func geometryDidChange() {
        guard !suppressGeometryChanges else { return }
        onGeometryChange?(currentGeometry)
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
