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
        let duplicateCompletion = await model.setCompleted(first, completed: true)
        precondition(!duplicateCompletion, "A duplicate pending completion must not report another success")
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
        let firstSucceeded = await firstWrite.value
        let secondSucceeded = await secondWrite.value
        precondition(firstSucceeded && secondSucceeded, "Only persisted writes can report success")
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
        let failedUndo = await model.setCompleted(completedFirst, completed: false)
        precondition(!failedUndo, "Failed writes must not trigger success feedback")
        precondition(model.completionValue(for: completedFirst))
        precondition(!model.isCompleting(first.id) && model.errorMessage != nil)
        precondition(sqlite3_exec(lockConnection, "DROP TRIGGER fail_completion", nil, nil, nil) == SQLITE_OK)
        let successfulUndo = await model.setCompleted(completedFirst, completed: false)
        precondition(successfulUndo)
        precondition(model.incompleteTasks.contains { $0.id == first.id })
        precondition(model.errorMessage == nil)

        // Rows move between sections after each save. A concurrent refresh must not
        // leave the moved row pending or make a later completion change get rejected.
        for completed in [true, false, true, false] {
            let displayed = model.tasks.first { $0.id == first.id }!
            let write = Task { await model.setCompleted(displayed, completed: completed) }
            let refresh = Task { await model.refresh() }
            let succeeded = await write.value
            await refresh.value
            precondition(succeeded, "A row must accept repeated completion and undo operations")
            precondition(!model.isCompleting(first.id), "A moved row must become interactive after saving")
            let updated = model.tasks.first { $0.id == first.id }!
            precondition(updated.isCompleted == completed, "Section placement must match the saved state")
            precondition(model.completionValue(for: updated) == completed,
                         "The checkbox must match the row's saved completion styling")
            let saved = try store.fetchTasks().first { $0.id == first.id }!
            precondition(saved.isCompleted == completed)
        }

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

        try store.showStickyNotes(ids: [first.id])
        await model.refresh()
        await model.setStickyFontSize(id: first.id, fontSize: 24)
        precondition(sqlite3_exec(lockConnection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        var preferenceStarted = false
        let preferenceWrite = Task {
            preferenceStarted = true
            await model.setDefaultStickyFontSize(22)
        }
        while !preferenceStarted { await Task.yield() }
        beganWaiting = false
        finishedWaiting = false
        let appearanceWait = Task {
            beganWaiting = true
            await model.waitForPendingSave()
            finishedWaiting = true
        }
        while !beganWaiting { await Task.yield() }
        precondition(!model.isSaving && !finishedWaiting, "Font preferences must save without locking the list, and quit must wait")
        precondition(sqlite3_exec(lockConnection, "COMMIT", nil, nil, nil) == SQLITE_OK)
        await preferenceWrite.value
        await appearanceWait.value
        precondition(model.defaultStickyFontSize == 22)
        let overridden = model.stickyNotes.first { $0.id == first.id }!
        precondition(model.effectiveStickyFontSize(for: overridden) == 24)
        await model.setStickyFontSize(id: first.id, fontSize: nil)
        let inherited = model.stickyNotes.first { $0.id == first.id }!
        precondition(model.effectiveStickyFontSize(for: inherited) == 22)
        withExtendedLifetime(subscription) {}
        print("TodoListModelTests passed")
    }
}
