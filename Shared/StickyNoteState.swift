import Foundation

struct StickyNotePosition: Equatable, Sendable {
    let x: Double
    let y: Double
    let displayID: String?
}

struct StickyNoteState: Identifiable, Equatable, Sendable {
    let id: UUID
    let isVisible: Bool
    let isAlwaysOnTop: Bool
    let position: StickyNotePosition?
}

struct TodoSnapshot: Equatable, Sendable {
    let tasks: [TodoItem]
    let stickyNotes: [StickyNoteState]
}
