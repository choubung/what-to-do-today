import Foundation

struct TodoCategory: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let isDefault: Bool
    /// Includes completed tasks outside today's list, so deletion previews remain accurate.
    let taskCount: Int

    init(id: UUID, name: String, isDefault: Bool = false, taskCount: Int = 0) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.taskCount = taskCount
    }

    static let maximumNameLength = 30
}

struct TodoItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let completedAt: Date?
    let categoryID: UUID?

    init(id: UUID, title: String, createdAt: Date, completedAt: Date?, categoryID: UUID? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.categoryID = categoryID
    }

    var isCompleted: Bool { completedAt != nil }
}

struct TodoPage: Equatable, Sendable {
    let tasks: [TodoItem]
    let index: Int
    let pageSize: Int
    let totalCount: Int

    var pageCount: Int { max(1, (totalCount - 1) / pageSize + 1) }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { index + 1 < pageCount }
}
