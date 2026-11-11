import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}

private final class ConcurrentFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(error.localizedDescription)
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        try expect(messages.isEmpty, "Concurrent writes failed: \(messages)")
    }
}

@main
private enum TaskStoreTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("what-to-do-today-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let startupFailures = ConcurrentFailures()
        // Opening an existing WAL database misses the initial journal-mode transition race.
        for attempt in 0..<100 {
            let coldDatabaseURL = directory.appendingPathComponent("cold-start-\(attempt)/Tasks.sqlite")
            DispatchQueue.concurrentPerform(iterations: 2) { worker in
                do {
                    let store = try TodoStore(databaseURL: coldDatabaseURL)
                    try store.addTask(title: "최초 실행 \(worker)")
                } catch {
                    startupFailures.append(error)
                }
            }
            try startupFailures.check()
            let savedTasks = try TodoStore(databaseURL: coldDatabaseURL).fetchTasks()
            try expect(savedTasks.count == 2, "Concurrent first opens must preserve both successful writes")
        }

        let databaseURL = directory.appendingPathComponent("Tasks.sqlite")
        let appStore = try TodoStore(databaseURL: databaseURL)
        let widgetStore = try TodoStore(databaseURL: databaseURL)

        try expect(try appStore.fetchPage(index: 10, pageSize: 4).index == 0, "Empty page must clamp to zero")
        do {
            try appStore.addTask(title: " \n\t ")
            throw TestFailure(description: "Empty title was accepted")
        } catch TodoStoreError.emptyTitle {
            // The same validation protects both app entry points and widget quick add.
        }

        let first = try appStore.addTask(title: "  오늘 할 일 📝  ")
        let second = try widgetStore.addTask(title: "회의 자료 '정리'\0하기")
        try expect(try appStore.fetchTasks().map(\.id) == [second.id, first.id], "Newest incomplete task should appear first")
        try expect(try widgetStore.fetchTasks().last?.title == "오늘 할 일 📝", "Unicode title should round-trip and trim")
        try expect(try appStore.fetchTasks().first?.title == second.title, "Embedded null and quotes should round-trip")

        try appStore.setCompleted(id: second.id, completed: true)
        let completedAt = try widgetStore.fetchTasks().last?.completedAt
        try widgetStore.setCompleted(id: second.id, completed: true)
        try expect(try appStore.fetchTasks().last?.completedAt == completedAt, "Retried completion must preserve completion date")
        try expect(try appStore.fetchTasks().map(\.id) == [first.id, second.id], "Incomplete tasks must sort before completed tasks")
        try appStore.setCompleted(id: first.id, completed: true)
        try expect(try widgetStore.fetchTasks().map(\.id) == [first.id, second.id], "Newest completion should appear first")
        try widgetStore.setCompleted(id: second.id, completed: false)
        try expect(try appStore.fetchTasks().first?.id == second.id, "Undo completion must return task to incomplete group")
        try appStore.updateTask(id: second.id, title: "  수정한 할 일  ")
        try expect(try widgetStore.fetchTasks().first?.title == "수정한 할 일", "Another connection must observe title updates")

        let page = try widgetStore.fetchPage(index: Int.max, pageSize: 1)
        try expect(page.index == 1 && page.tasks.first?.id == first.id, "Page must clamp to the last available page")
        try expect(page.hasPrevious && !page.hasNext && page.pageCount == 2, "Navigation bounds must match snapshot")
        try appStore.deleteTask(id: first.id)
        try appStore.deleteTask(id: first.id)
        let afterDelete = try widgetStore.fetchPage(index: page.index, pageSize: 1)
        try expect(afterDelete.index == 0 && afterDelete.tasks.first?.id == second.id, "Deleting last page must reveal preceding page")

        do {
            try widgetStore.setCompleted(id: first.id, completed: false)
            throw TestFailure(description: "Deleted task was resurrected")
        } catch TodoStoreError.missingTask {
            // Stale widget interactions must not recreate deleted data.
        }

        let failures = ConcurrentFailures()
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            do {
                let store = try TodoStore(databaseURL: databaseURL)
                for index in 0..<40 {
                    let task = try store.addTask(title: "동시 작성 \(worker)-\(index)")
                    try store.setCompleted(id: task.id, completed: index.isMultiple(of: 2))
                }
            } catch {
                failures.append(error)
            }
        }
        try failures.check()
        let persisted = try TodoStore(databaseURL: databaseURL).fetchTasks()
        try expect(persisted.count == 161, "Concurrent connections must preserve every write")
        try expect(Set(persisted.map(\.id)).count == 161, "Stored task IDs must remain unique")
        let largePage = try appStore.fetchPage(index: 0, pageSize: Int.max)
        try expect(largePage.pageCount == 1 && largePage.tasks.count == 161, "Large page sizes must not overflow")
        print("Passed local-store cold start, CRUD, Unicode, completion retries, sorting, pagination, and concurrent connection tests.")
    }
}
