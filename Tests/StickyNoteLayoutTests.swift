import Foundation
import CoreGraphics

private struct LayoutFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw LayoutFailure(description: message) }
}

@main
private enum StickyNoteLayoutTests {
    static func main() throws {
        let main = StickyNoteLayout.Screen(
            id: "main", visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 840), isPrimary: true
        )
        let left = StickyNoteLayout.Screen(
            id: "left", visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), isPrimary: false
        )
        let size = CGSize(width: 280, height: 190)

        let restored = StickyNoteLayout.placement(
            savedOrigin: CGPoint(x: -1200, y: 300), displayID: "left", size: size, screens: [main, left]
        )!
        try expect(restored.frame.origin == CGPoint(x: -1200, y: 300), "Negative external-monitor coordinates must survive restore")
        try expect(restored.displayID == "left", "Saved monitor should be preferred while connected")

        let removed = StickyNoteLayout.placement(
            savedOrigin: restored.frame.origin, displayID: "left", size: size, screens: [main]
        )!
        try expect(main.visibleFrame.contains(removed.frame), "A disconnected monitor must not leave the note offscreen")
        try expect(removed.displayID == "main", "Disconnected display must map to the remaining monitor")

        let overlapping = StickyNoteLayout.placement(
            savedOrigin: CGPoint(x: -250, y: 350), displayID: "gone", size: size, screens: [main, left]
        )!
        try expect(overlapping.displayID == "left", "Missing monitor should choose the screen with largest overlap")
        try expect(left.visibleFrame.contains(overlapping.frame), "Partially offscreen notes must become fully visible")

        let movedMonitor = StickyNoteLayout.placement(
            savedOrigin: CGPoint(x: 100, y: 100), displayID: "left", size: size, screens: [main, left]
        )!
        try expect(movedMonitor.displayID == "left" && left.visibleFrame.contains(movedMonitor.frame), "A connected saved display remains preferred after rearrangement")

        let tiny = StickyNoteLayout.Screen(
            id: "tiny", visibleFrame: CGRect(x: 20, y: -100, width: 180, height: 110), isPrimary: true
        )
        let shrunken = StickyNoteLayout.placement(
            savedOrigin: CGPoint(x: 5000, y: 5000), displayID: nil, size: size, screens: [tiny]
        )!
        try expect(shrunken.frame == tiny.visibleFrame, "A smaller visible screen must constrain both note size and origin")

        let first = StickyNoteLayout.placement(savedOrigin: nil, displayID: nil, size: size, screens: [main])!
        let second = StickyNoteLayout.placement(savedOrigin: nil, displayID: nil, size: size, cascadeIndex: 1, screens: [main])!
        try expect(first.frame != second.frame, "New notes should cascade instead of completely covering each other")
        for index in 0..<100 {
            let placement = StickyNoteLayout.placement(savedOrigin: nil, displayID: nil, size: size, cascadeIndex: index, screens: [main])!
            try expect(main.visibleFrame.contains(placement.frame), "Every cascaded note must remain onscreen")
        }
        try expect(StickyNoteLayout.placement(savedOrigin: nil, displayID: nil, size: size, screens: []) == nil, "No screens must be handled without a crash")
        let invalidOrigin = StickyNoteLayout.placement(savedOrigin: CGPoint(x: CGFloat.nan, y: 0), displayID: nil, size: size, screens: [main])!
        try expect(main.visibleFrame.contains(invalidOrigin.frame), "Invalid stored coordinates should use a safe default")
        print("Passed sticky-note restore, monitor removal, negative coordinates, bounds, and cascade tests.")
    }
}
