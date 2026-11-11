import Foundation

struct StickyNotePosition: Equatable, Sendable {
    let x: Double
    let y: Double
    let displayID: String?
}

struct StickyNoteSize: Equatable, Sendable {
    let width: Double
    let height: Double
}

enum StickyNoteTypography {
    static let defaultFontSize: Double = 17
    static let minimumFontSize: Double = 12
    static let maximumFontSize: Double = 32
    static let fontSizeStep: Double = 2
}

struct StickyNoteState: Identifiable, Equatable, Sendable {
    let id: UUID
    let isVisible: Bool
    let isAlwaysOnTop: Bool
    let position: StickyNotePosition?
    let size: StickyNoteSize?
    let fontSize: Double?

    init(
        id: UUID, isVisible: Bool, isAlwaysOnTop: Bool, position: StickyNotePosition?,
        size: StickyNoteSize? = nil, fontSize: Double? = nil
    ) {
        self.id = id
        self.isVisible = isVisible
        self.isAlwaysOnTop = isAlwaysOnTop
        self.position = position
        self.size = size
        self.fontSize = fontSize
    }
}

struct TodoSnapshot: Equatable, Sendable {
    let tasks: [TodoItem]
    let stickyNotes: [StickyNoteState]
    let stickyNoteDefaultFontSize: Double
    let categories: [TodoCategory]

    init(
        tasks: [TodoItem], stickyNotes: [StickyNoteState],
        stickyNoteDefaultFontSize: Double = StickyNoteTypography.defaultFontSize,
        categories: [TodoCategory] = []
    ) {
        self.tasks = tasks
        self.stickyNotes = stickyNotes
        self.stickyNoteDefaultFontSize = stickyNoteDefaultFontSize
        self.categories = categories
    }
}
