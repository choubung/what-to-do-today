import AppKit
import SwiftUI

@MainActor
final class CompletionFeedbackController {
    private var panel: CompletionFeedbackPanel?
    private var dismissal: Task<Void, Never>?
    private var presentationID = UUID()

    deinit { dismissal?.cancel() }

    func show(near sourceFrame: CGRect) {
        let screens = NSScreen.screens
        let overlapping = screens.max {
            overlap(sourceFrame, $0.visibleFrame) < overlap(sourceFrame, $1.visibleFrame)
        }
        let screen = overlapping.flatMap { overlap(sourceFrame, $0.visibleFrame) > 0 ? $0 : nil }
            ?? NSScreen.main ?? screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let size = CGSize(width: min(176, visible.width), height: min(52, visible.height))
        let origin = CGPoint(
            x: min(max(sourceFrame.midX - size.width / 2, visible.minX), visible.maxX - size.width),
            y: min(max(sourceFrame.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        )
        let panel = panel ?? makePanel()
        self.panel = panel
        dismissal?.cancel()
        let id = UUID()
        presentationID = id
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        // Display in the current Space without changing the app or keyboard focus.
        panel.orderFrontRegardless()
        NSAccessibility.post(
            element: NSApp, notification: .announcementRequested,
            userInfo: [.announcement: "완료했어요", .priority: NSAccessibilityPriorityLevel.low.rawValue]
        )
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, !Task.isCancelled, presentationID == id else { return }
            self.panel?.orderOut(nil)
            dismissal = nil
        }
    }

    private func makePanel() -> CompletionFeedbackPanel {
        let panel = CompletionFeedbackPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "완료했어요"
        panel.setAccessibilityLabel("완료했어요")
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let content = NSHostingView(rootView: CompletionFeedbackView())
        content.sizingOptions = []
        panel.contentView = content
        return panel
    }

    private func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

@MainActor
private final class CompletionFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CompletionFeedbackView: View {
    var body: some View {
        Label("완료했어요", systemImage: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("완료했어요")
    }
}
