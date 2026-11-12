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
    let colorHex: String?
    let categoryColorHex: String?

    var effectiveColorHex: String? { colorHex ?? categoryColorHex }

    init(
        id: UUID, isVisible: Bool, isAlwaysOnTop: Bool, position: StickyNotePosition?,
        size: StickyNoteSize? = nil, fontSize: Double? = nil, colorHex: String? = nil, categoryColorHex: String? = nil
    ) {
        self.id = id
        self.isVisible = isVisible
        self.isAlwaysOnTop = isAlwaysOnTop
        self.position = position
        self.size = size
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.categoryColorHex = categoryColorHex
    }
}

struct TodoSnapshot: Equatable, Sendable {
    let tasks: [TodoItem]
    let upcomingTasks: [TodoItem]
    let stickyNotes: [StickyNoteState]
    let canRestoreStickyNotes: Bool
    let stickyNoteDefaultFontSize: Double
    let categories: [TodoCategory]
    let reminders: [TodoReminder]

    init(
        tasks: [TodoItem], stickyNotes: [StickyNoteState], canRestoreStickyNotes: Bool = false,
        stickyNoteDefaultFontSize: Double = StickyNoteTypography.defaultFontSize,
        categories: [TodoCategory] = [],
        reminders: [TodoReminder] = [], upcomingTasks: [TodoItem] = []
    ) {
        self.tasks = tasks
        self.upcomingTasks = upcomingTasks
        self.stickyNotes = stickyNotes
        self.canRestoreStickyNotes = canRestoreStickyNotes
        self.stickyNoteDefaultFontSize = stickyNoteDefaultFontSize
        self.categories = categories
        self.reminders = reminders
    }
}
