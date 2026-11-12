import Foundation

struct TodoCategory: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isDefault: Bool
    /// Includes completed tasks outside today's list, so deletion previews remain accurate.
    let taskCount: Int
    let stickyColorHex: String?

    init(id: UUID, name: String, isDefault: Bool = false, taskCount: Int = 0, stickyColorHex: String? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.taskCount = taskCount
        self.stickyColorHex = stickyColorHex
    }

    static let maximumNameLength = 30
}

/// A Gregorian calendar date in the Mac's local time zone, without a time of day.
enum TodoPlannedDay {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    static func key(for date: Date) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year! * 10_000 + components.month! * 100 + components.day!
    }

    static func date(for key: Int) -> Date? {
        calendar.date(from: DateComponents(
            year: key / 10_000, month: key / 100 % 100, day: key % 100, hour: 12
        ))
    }
}

struct TodoItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let completedAt: Date?
    let categoryID: UUID?
    let plannedDay: Int?

    init(id: UUID, title: String, createdAt: Date, completedAt: Date?, categoryID: UUID? = nil, plannedDay: Int? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.categoryID = categoryID
        self.plannedDay = plannedDay
    }

    var isCompleted: Bool { completedAt != nil }
}

struct TodoPage: Equatable, Sendable {
    let tasks: [TodoItem]
    let index: Int
    let pageSize: Int
    let totalCount: Int
    let pageCount: Int

    init(tasks: [TodoItem], index: Int, pageSize: Int, totalCount: Int) {
        self.tasks = tasks
        self.index = index
        self.pageSize = pageSize
        self.totalCount = totalCount
        self.pageCount = max(1, (totalCount - 1) / pageSize + 1)
    }

    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index + 1 < pageCount }
}
