import Foundation
import CoreGraphics

/// Screen geometry is separate from AppKit so display changes can be tested without hardware.
enum StickyNoteLayout {
    static let defaultSize = CGSize(width: 280, height: 190)
    static let minimumSize = CGSize(width: 240, height: 160)

    /// Bottom-right resize keeps the top-left corner fixed in screen coordinates.
    static func resizedFrame(from initial: CGRect, delta: CGPoint, minimumSize: CGSize) -> CGRect {
        let size = CGSize(
            width: max(minimumSize.width, initial.width + delta.x),
            height: max(minimumSize.height, initial.height - delta.y)
        )
        return CGRect(x: initial.minX, y: initial.maxY - size.height, width: size.width, height: size.height)
    }

    struct Screen: Equatable {
        let id: String
        let visibleFrame: CGRect
        let isPrimary: Bool
    }

    struct Placement: Equatable {
        let frame: CGRect
        let displayID: String
    }

    static func placement(
        savedOrigin: CGPoint?,
        displayID: String?,
        size: CGSize,
        cascadeIndex: Int = 0,
        screens: [Screen]
    ) -> Placement? {
        let screens = screens.filter { valid($0.visibleFrame) }
        guard let primary = screens.first(where: \.isPrimary) ?? screens.first,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }

        let origin = savedOrigin.flatMap { point in
            point.x.isFinite && point.y.isFinite ? point : nil
        }
        let usableSize = CGSize(
            width: max(size.width, minimumSize.width),
            height: max(size.height, minimumSize.height)
        )
        let proposed = CGRect(origin: origin ?? .zero, size: usableSize)
        let screen: Screen
        if let preferred = screens.first(where: { $0.id == displayID }) {
            screen = preferred
        } else if origin != nil,
                  let overlapping = screens.max(by: {
                      overlapArea(proposed, $0.visibleFrame) < overlapArea(proposed, $1.visibleFrame)
                  }), overlapArea(proposed, overlapping.visibleFrame) > 0 {
            screen = overlapping
        } else {
            screen = primary
        }

        let visible = screen.visibleFrame
        let fittedSize = CGSize(
            width: min(usableSize.width, visible.width),
            height: min(usableSize.height, visible.height)
        )
        let offset = CGFloat(max(0, cascadeIndex) % 8) * 22
        let desired = origin ?? CGPoint(
            x: visible.minX + 24 + offset,
            y: visible.maxY - fittedSize.height - 24 - offset
        )
        let fittedOrigin = CGPoint(
            x: min(max(desired.x, visible.minX), visible.maxX - fittedSize.width),
            y: min(max(desired.y, visible.minY), visible.maxY - fittedSize.height)
        )
        return Placement(frame: CGRect(origin: fittedOrigin, size: fittedSize), displayID: screen.id)
    }

    private static func overlapArea(_ frame: CGRect, _ screen: CGRect) -> CGFloat {
        let intersection = frame.intersection(screen)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}
