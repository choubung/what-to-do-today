import Combine
import Foundation
import SQLite3

@main
private enum TodoListModelTests {
    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("todo-model-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("Tasks.sqlite")
        let store = try TodoStore(databaseURL: databaseURL)
        let first = try store.addTask(title: "first")
        let second = try store.addTask(title: "second")
        let model = TodoListModel(store: store, broadcastsChanges: false)
        await model.refresh()
        await model.refresh()

        var publications = 0
        let subscription = model.$snapshot.sink { _ in publications += 1 }
        await model.refresh()
        await model.refresh()
        precondition(publications == 1, "An unchanged refresh must not republish the list")

        var lockConnection: OpaquePointer?
        precondition(sqlite3_open(databaseURL.path, &lockConnection) == SQLITE_OK)
        defer { sqlite3_close(lockConnection) }
        precondition(sqlite3_exec(lockConnection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        // Hold a real database write so the UI's pending state is observable deterministically.
        let firstWrite = Task { await model.setCompleted(first, completed: true) }
        let secondWrite = Task { await model.setCompleted(second, completed: true) }
        let deadline = Date().addingTimeInterval(2)
        while !model.isCompleting(first.id) || !model.isCompleting(second.id) {
            precondition(Date() < deadline, "Both rows must start saving independently")
            await Task.yield()
        }
        precondition(!model.isSaving, "Completing a row must not disable the whole app")
        precondition(model.completionValue(for: first) && model.completionValue(for: second))
        var beganWaiting = false
        var finishedWaiting = false
        let terminationWait = Task {
            beganWaiting = true
            await model.waitForPendingSave()
            finishedWaiting = true
        }
        while !beganWaiting { await Task.yield() }
        precondition(!finishedWaiting, "Quit must wait for pending completion writes")
        precondition(sqlite3_exec(lockConnection, "COMMIT", nil, nil, nil) == SQLITE_OK)
        await firstWrite.value
        await secondWrite.value
        await terminationWait.value
        precondition(finishedWaiting && !model.isCompleting(first.id) && !model.isCompleting(second.id))
        precondition(model.completedTasks.count == 2)
        let savedTasks = try store.fetchTasks()
        precondition(savedTasks.allSatisfy(\.isCompleted))

        // A failed completion undo must restore the saved check and show a recoverable error.
        precondition(sqlite3_exec(lockConnection, """
            CREATE TRIGGER fail_completion BEFORE UPDATE OF completed_at ON todos
            BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;
            """, nil, nil, nil) == SQLITE_OK)
        let completedFirst = model.tasks.first { $0.id == first.id }!
        await model.setCompleted(completedFirst, completed: false)
        precondition(model.completionValue(for: completedFirst))
        precondition(!model.isCompleting(first.id) && model.errorMessage != nil)
        precondition(sqlite3_exec(lockConnection, "DROP TRIGGER fail_completion", nil, nil, nil) == SQLITE_OK)
        await model.setCompleted(completedFirst, completed: false)
        precondition(model.incompleteTasks.contains { $0.id == first.id })
        precondition(model.errorMessage == nil)

        // Each finished write must remain checked while other rows and refreshes are still in flight.
        let concurrentTasks = try (0..<40).map { try store.addTask(title: "concurrent \($0)") }
        await model.refresh()
        let completions = concurrentTasks.map { task in
            Task { @MainActor in
                await model.setCompleted(task, completed: true)
                let displayed = model.tasks.first { $0.id == task.id }!
                precondition(model.completionValue(for: displayed), "A superseded refresh must not undo the visible check")
            }
        }
        for completion in completions { await completion.value }
        precondition(concurrentTasks.allSatisfy { task in
            model.completedTasks.contains { $0.id == task.id }
        })
        withExtendedLifetime(subscription) {}
        print("TodoListModelTests passed")
    }
}
