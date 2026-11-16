import AppKit
import SwiftUI

private struct InteractionFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw InteractionFailure(description: message) }
}

/// These windows are never shown. Events go directly to their views, not the
/// system event queue, so this test cannot interact with the user's open notes.
@main
private enum StickyNoteInteractionTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sticky-interaction-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TodoStore(databaseURL: directory.appendingPathComponent("Tasks.sqlite"))
        let task = try store.addTask(title: "투명도 조절과 포스트잇 이동", showAsStickyNote: true)
        let model = TodoListModel(store: store, broadcastsChanges: false)
        await model.refresh()

        for size in [StickyNoteLayout.minimumSize, StickyNoteLayout.defaultSize] {
            guard let note = model.stickyNotes.first(where: { $0.id == task.id }) else {
                throw InteractionFailure(description: "The test note is missing")
            }
            try checkNoteInteraction(model: model, task: task, note: note, size: size)
            // The production SwiftUI binding saves on mouse-up in a Task.
            await Task.yield()
            await model.waitForPendingSave()
        }
        print("Passed offscreen sticky-note slider edge targeting, drag tracking, keyboard/accessibility, and window-movement isolation tests.")
    }

    @MainActor
    private static func checkNoteInteraction(
        model: TodoListModel, task: TodoItem, note: StickyNoteState, size: CGSize
    ) throws {
        let panel = NSPanel(
            contentRect: NSRect(origin: CGPoint(x: 300, y: 300), size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        var previews: [Int] = []
        let host = NSHostingView(rootView: StickyNoteView(
            model: model, task: task, note: note,
            onPreviewOpacity: { if let value = $0 { previews.append(value) } },
            onHide: {}, onComplete: {}
        ))
        host.safeAreaRegions = []
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(NSRect(origin: CGPoint(x: 300, y: 300), size: size), display: false)
        defer {
            panel.contentView = nil
            panel.close()
        }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw InteractionFailure(description: "Could not render the offscreen test note")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let slider: CompactOpacitySlider.SliderView = descendant(in: host),
              let dragArea: StickyNoteDragArea.DragView = descendant(in: host),
              let cell = slider.cell as? NSSliderCell else {
            throw InteractionFailure(description: "The rendered note is missing its interaction controls")
        }

        try expect(slider.bounds.size == CGSize(width: 72, height: 28),
                   "The native slider must fill its 72×28 target even on a \(size) note")
        try expect(dragArea.bounds.width > 0, "The smallest note must retain a blank area for moving")
        let originalFrame = panel.frame
        var editingEvents: [Bool] = []
        let originalEditing = slider.onEditingChanged
        slider.onEditingChanged = { editing in
            editingEvents.append(editing)
            originalEditing?(editing)
        }

        // A fixed SwiftUI frame previously left unowned strips above and below
        // NSSlider. Check the actual containing view's hit-test, not its bounds alone.
        for y: CGFloat in [1, 27] {
            let point = CGPoint(x: 24, y: y)
            let parentPoint = slider.convert(point, to: host.superview)
            try expect(host.hitTest(parentPoint) === slider,
                       "The slider's y=\(y) edge must not fall through to titlebar dragging")
            slider.doubleValue = 100
            editingEvents.removeAll()
            slider.mouseDown(with: try event(.leftMouseDown, in: slider, at: point))
            slider.mouseUp(with: try event(.leftMouseUp, in: slider, at: point))
            try expect(slider.doubleValue < 100, "An edge click must change opacity")
            try expect(editingEvents == [true, false], "A pointer gesture must begin and end editing once")
            try expect(panel.frame == originalFrame, "Adjusting opacity must never move or resize the note")
        }
        try expect(!previews.isEmpty, "Pointer changes must reach the real note's live-preview binding")

        // Starting inside the thumb's horizontal hit area should preserve the
        // grabbed offset, including above its tiny visible circle.
        slider.doubleValue = 65
        let knob = cell.knobRect(flipped: slider.isFlipped)
        let grab = CGPoint(x: knob.midX + 3, y: 1)
        editingEvents.removeAll()
        slider.mouseDown(with: try event(.leftMouseDown, in: slider, at: grab))
        try expect(slider.doubleValue == 65, "Grabbing the side of the thumb must not jump its value")
        slider.mouseDragged(with: try event(.leftMouseDragged, in: slider, at: CGPoint(x: grab.x + 8, y: 27)))
        try expect(slider.doubleValue > 65, "Dragging a grabbed thumb must adjust opacity")
        slider.mouseDragged(with: try event(.leftMouseDragged, in: slider, at: CGPoint(x: 200, y: 80)))
        try expect(slider.doubleValue == 100, "Dragging past the right edge must clamp to 100%")
        slider.mouseDragged(with: try event(.leftMouseDragged, in: slider, at: CGPoint(x: -100, y: -40)))
        try expect(slider.doubleValue == 30, "Dragging past the left edge must clamp to 30%")
        slider.mouseUp(with: try event(.leftMouseUp, in: slider, at: CGPoint(x: -100, y: -40)))
        try expect(editingEvents == [true, false], "Leaving the target must not interrupt the edit lifecycle")
        try expect(panel.frame == originalFrame, "A slider drag outside its bounds must not move the note")

        // Exercise AppKit's resolved keyboard command; keyDown on an offscreen
        // plain NSSlider does not resolve key bindings without the app event loop.
        // Accessibility returns false on this OS even when it changes the value,
        // so assert its observable value/action effects instead of the return flag.
        slider.doubleValue = 65
        let previewCount = previews.count
        slider.moveRight(nil)
        try expect(slider.doubleValue > 65, "The move-right keyboard command must still increase opacity")
        try expect(previews.count > previewCount, "Keyboard changes must reach the note binding")
        let beforeIncrement = slider.doubleValue
        let beforeAccessibleAction = previews.count
        _ = slider.accessibilityPerformIncrement()
        try expect(slider.doubleValue > beforeIncrement, "Accessibility increment must update opacity")
        try expect(previews.count > beforeAccessibleAction, "Accessibility changes must reach the note binding")

        // Moving is deliberately isolated to the blank area. Keep the pointer's
        // screen coordinate stable after moving the window, like real NSEvents.
        let start = dragArea.convert(CGPoint(x: dragArea.bounds.midX, y: dragArea.bounds.midY), to: nil)
        let startScreen = panel.convertPoint(toScreen: start)
        let endScreen = CGPoint(x: startScreen.x + 25, y: startScreen.y - 15)
        dragArea.mouseDown(with: try event(.leftMouseDown, window: panel, location: start))
        dragArea.mouseDragged(with: try event(
            .leftMouseDragged, window: panel, location: panel.convertPoint(fromScreen: endScreen)
        ))
        dragArea.mouseUp(with: try event(
            .leftMouseUp, window: panel, location: panel.convertPoint(fromScreen: endScreen)
        ))
        try expect(panel.frame.origin == CGPoint(x: originalFrame.minX + 25, y: originalFrame.minY - 15),
                   "The blank area must move the note by the pointer delta")
        let movedFrame = panel.frame
        slider.mouseDown(with: try event(.leftMouseDown, in: slider, at: CGPoint(x: 50, y: 27)))
        slider.mouseUp(with: try event(.leftMouseUp, in: slider, at: CGPoint(x: 50, y: 27)))
        try expect(panel.frame == movedFrame, "A preceding note move must not leak into the next slider gesture")

        // The pointer can enter the menu bar during a drag. The only move target
        // must remain visible there so the note can be grabbed and moved back.
        guard let screen = panel.screen ?? NSScreen.main else {
            throw InteractionFailure(description: "The test window has no display")
        }
        let upperStart = dragArea.convert(CGPoint(x: dragArea.bounds.midX, y: dragArea.bounds.midY), to: nil)
        let upperTarget = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
        dragArea.mouseDown(with: try event(.leftMouseDown, window: panel, location: upperStart))
        dragArea.mouseDragged(with: try event(
            .leftMouseDragged, window: panel, location: panel.convertPoint(fromScreen: upperTarget)
        ))
        dragArea.mouseUp(with: try event(
            .leftMouseUp, window: panel, location: panel.convertPoint(fromScreen: upperTarget)
        ))
        let upperDragRect = panel.convertToScreen(dragArea.convert(dragArea.bounds, to: nil))
        try expect(screen.visibleFrame.contains(upperDragRect),
                   "Dragging into the menu bar must keep the blank move target visible")
        try expect(panel.frame.size == originalFrame.size, "Constraining a move must preserve the note's size")

        let upperFrame = panel.frame
        let recoveryStart = dragArea.convert(CGPoint(x: dragArea.bounds.midX, y: dragArea.bounds.midY), to: nil)
        let recoveryScreenStart = panel.convertPoint(toScreen: recoveryStart)
        let recoveryTarget = CGPoint(x: recoveryScreenStart.x, y: recoveryScreenStart.y - 60)
        dragArea.mouseDown(with: try event(.leftMouseDown, window: panel, location: recoveryStart))
        dragArea.mouseDragged(with: try event(
            .leftMouseDragged, window: panel, location: panel.convertPoint(fromScreen: recoveryTarget)
        ))
        dragArea.mouseUp(with: try event(
            .leftMouseUp, window: panel, location: panel.convertPoint(fromScreen: recoveryTarget)
        ))
        try expect(panel.frame.origin == CGPoint(x: upperFrame.minX, y: upperFrame.minY - 60),
                   "A note at the top edge must remain draggable back into the screen")
        try expect(!panel.isVisible, "Interaction checks must never display a window")
    }

    @MainActor
    private static func descendant<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match: T = descendant(in: child) { return match }
        }
        return nil
    }

    @MainActor
    private static func event(_ type: NSEvent.EventType, in view: NSView, at point: CGPoint) throws -> NSEvent {
        guard let window = view.window else { throw InteractionFailure(description: "The test view has no window") }
        return try event(type, window: window, location: view.convert(point, to: nil))
    }

    @MainActor
    private static func event(_ type: NSEvent.EventType, window: NSWindow, location: CGPoint) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ) else { throw InteractionFailure(description: "Could not construct a local pointer event") }
        return event
    }
}
