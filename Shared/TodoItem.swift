import Foundation

struct TodoItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let completedAt: Date?

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
