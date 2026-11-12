import Foundation
import SQLite3

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}

private func executeLegacySQL(_ sql: String, at url: URL) throws {
    var connection: OpaquePointer?
    let opened = sqlite3_open(url.path, &connection)
    defer { sqlite3_close(connection) }
    guard opened == SQLITE_OK, sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
        throw TestFailure(description: "Legacy database fixture failed: \(String(cString: sqlite3_errmsg(connection)))")
    }
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
    private static func testCategoryStickyColors(in directory: URL) throws {
        let url = directory.appendingPathComponent("category-colors.sqlite")
        let store = try TodoStore(databaseURL: url)
        let work = try store.createCategory(name: "업무")
        let home = try store.createCategory(name: "개인")
        let task = try store.addTask(title: "색상 상속", categoryID: work.id, showAsStickyNote: true)
        let custom = try store.addTask(title: "개별 색상", categoryID: work.id, showAsStickyNote: true)
        try store.saveStickyColor(id: custom.id, colorHex: "#123456")
        // An existing database without the new column must keep task and note data on upgrade.
        try executeLegacySQL("ALTER TABLE categories DROP COLUMN sticky_color_hex", at: url)
        let upgraded = try TodoStore(databaseURL: url)
        try expect(try upgraded.fetchSnapshot().stickyNotes.first { $0.id == custom.id }?.colorHex == "#123456", "Migration preserves individual colors")
        try upgraded.saveCategoryStickyColor(id: work.id, colorHex: "#aabbcc")
        try upgraded.saveCategoryStickyColor(id: home.id, colorHex: "#E0F3E7")
        func note(_ id: UUID) throws -> StickyNoteState {
            try upgraded.fetchSnapshot().stickyNotes.first { $0.id == id }!
        }
        try expect(try note(task.id).effectiveColorHex == "#AABBCC", "Existing uncolored notes inherit normalized category color")
        try expect(try note(custom.id).effectiveColorHex == "#123456", "Individual colors take precedence")
        try upgraded.saveCategoryStickyColor(id: work.id, colorHex: "#ECE4FA")
        try expect(try note(task.id).effectiveColorHex == "#ECE4FA", "Category changes update inherited color")
        try upgraded.setCategory(id: task.id, categoryID: home.id)
        try expect(try note(task.id).effectiveColorHex == "#E0F3E7", "Moving a task follows its destination color")
        try upgraded.saveStickyColor(id: custom.id, colorHex: nil)
        try expect(try note(custom.id).effectiveColorHex == "#ECE4FA", "Resetting individual color restores inheritance")
        try upgraded.deleteCategory(id: work.id, movingTasksTo: home.id)
        try expect(try note(custom.id).effectiveColorHex == "#E0F3E7", "Category deletion adopts destination color")
        try expect(try TodoStore(databaseURL: url).fetchCategories().first { $0.id == home.id }?.stickyColorHex == "#E0F3E7", "Category color survives reopening")
        do {
            try upgraded.saveCategoryStickyColor(id: home.id, colorHex: "invalid")
            throw TestFailure(description: "Invalid category color accepted")
        } catch TodoStoreError.invalidColor {}
        do {
            try upgraded.saveCategoryStickyColor(id: UUID(), colorHex: nil)
            throw TestFailure(description: "Missing category silently accepted")
        } catch TodoStoreError.missingCategory {}
        try upgraded.saveCategoryStickyColor(id: home.id, colorHex: nil)
        try expect(try note(task.id).effectiveColorHex == nil, "Reset category color restores system default")
    }

    private static func testCategoryOrder(in directory: URL) throws {
        let url = directory.appendingPathComponent("category-order.sqlite")
        let store = try TodoStore(databaseURL: url)
        let defaultID = try store.fetchCategories()[0].id
        let work = try store.createCategory(name: "업무")
        let personal = try store.createCategory(name: "개인")
        let order = [personal.id, work.id, defaultID]
        try store.reorderCategories(ids: order)
        try store.renameCategory(id: personal.id, name: "취미")
        let reopened = try TodoStore(databaseURL: url)
        try expect(try reopened.fetchCategories().map(\.id) == order, "Order must survive rename and reopening, including moving the default")
        try expect(try reopened.addTask(title: "기본 추가").categoryID == defaultID, "Moving the default must not change automatic assignment")
        for invalid in [[personal.id, work.id], [personal.id, personal.id, defaultID], [personal.id, work.id, UUID()]] {
            do {
                try store.reorderCategories(ids: invalid)
                throw TestFailure(description: "Invalid category order accepted")
            } catch TodoStoreError.invalidCategoryOrder {}
        }
        try expect(try store.fetchCategories().map(\.id) == order, "Rejected stale orders must not modify saved positions")
        try executeLegacySQL("CREATE TRIGGER fail_order BEFORE UPDATE OF sort_order ON categories WHEN NEW.id = '\(work.id.uuidString)' BEGIN SELECT RAISE(ABORT, 'order failure'); END;", at: url)
        do {
            try store.reorderCategories(ids: [defaultID, work.id, personal.id])
            throw TestFailure(description: "Injected reorder failure ignored")
        } catch TodoStoreError.database {}
        try expect(try store.fetchCategories().map(\.id) == order, "Partial reorder failure must roll back every position")
        try executeLegacySQL("DROP TRIGGER fail_order", at: url)
        let added = try store.createCategory(name: "새 분류")
        try expect(try store.fetchCategories().map(\.id) == order + [added.id], "New categories append after saved order")
        try store.deleteCategory(id: work.id, movingTasksTo: personal.id)
        try expect(try store.fetchCategories().map(\.id) == [personal.id, defaultID, added.id], "Deletion preserves relative ordering")
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("what-to-do-today-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try testCategoryStickyColors(in: directory)
        try testCategoryOrder(in: directory)
        try testWidgetCategoryOrder(in: directory)

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
        try testStickyNotePersistence(in: directory)
        try testStickyNoteConcurrency(in: directory)
        try testAddTaskWithStickyNote(in: directory)
        try testDayFiltering(in: directory)
        try testTodayOnlyPagination(in: directory)
        try testPlannedTasks(in: directory)
        try testCompletionCalendar(in: directory)
        try testStickySizePersistence(in: directory)
        try testStickyFontPersistence(in: directory)
        try testStickyColorPersistence(in: directory)
        try testCategories(in: directory)
        try testRequiredCategoryMigration(in: directory)
        try testReminders(in: directory)
        print("Passed local-store cold start, CRUD, Unicode, completion retries, sorting, pagination, concurrency, and sticky-note migration/state tests.")
    }

    private static func testStickyColorPersistence(in directory: URL) throws {
        let url = directory.appendingPathComponent("legacy-p1-colors.sqlite")
        let id = UUID()
        try executeLegacySQL("""
            CREATE TABLE todos (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL,
                created_at REAL NOT NULL, completed_at REAL
            );
            CREATE TABLE sticky_notes (
                todo_id TEXT PRIMARY KEY NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
                is_visible INTEGER NOT NULL DEFAULT 0,
                is_always_on_top INTEGER NOT NULL DEFAULT 0,
                position_x REAL, position_y REAL, display_id TEXT,
                width REAL, height REAL, font_size REAL
            );
            INSERT INTO todos VALUES ('\(id.uuidString)', '기존 포스트잇', 100, NULL);
            INSERT INTO sticky_notes VALUES ('\(id.uuidString)', 1, 1, 40, 80, 'display', 300, 220, 20);
            """, at: url)
        let store = try TodoStore(databaseURL: url)
        let migrated = try store.fetchSnapshot().stickyNotes.first!
        try expect(migrated.colorHex == nil && migrated.isVisible && migrated.isAlwaysOnTop,
                   "Legacy notes must retain their visibility and use the existing default color")
        try expect(migrated.fontSize == 20 && migrated.size == StickyNoteSize(width: 300, height: 220),
                   "Color migration must preserve note typography and geometry")
        try store.saveStickyColor(id: id, colorHex: "  #aBcD09  ")
        let reopened = try TodoStore(databaseURL: url)
        try expect(try reopened.fetchSnapshot().stickyNotes.first?.colorHex == "#ABCD09",
                   "Another connection and a reopened store must read the canonical selected color")

        for invalid in ["", "#FFF", "#00000000", "#GGHHII", "+12345", "#１２３４５６", "AABBCC\0"] {
            try expect(StickyNoteColor(hex: invalid) == nil, "Malformed RGB hex must not be parsed")
            do {
                try store.saveStickyColor(id: id, colorHex: invalid)
                throw TestFailure(description: "Invalid note color accepted")
            } catch TodoStoreError.invalidColor {}
        }
        try expect(try reopened.fetchSnapshot().stickyNotes.first?.colorHex == "#ABCD09",
                   "An invalid color must not change the last saved color")

        for hex in ["#000000", "#FFFFFF", "#777777", "#0000FF", "#FF0000", "#00FF00", "#123456", "#FFF7D4"] {
            let color = StickyNoteColor(hex: hex)!
            let ratio = color.usesDarkText ? (color.luminance + 0.05) / 0.05 : 1.05 / (color.luminance + 0.05)
            try expect(ratio >= 4.5, "Chosen black/white text must remain legible on custom colors")
        }
        try expect(StickyNoteColor(hex: "ffffff")?.usesDarkText == true, "Light notes need dark text")
        try expect(StickyNoteColor(hex: "000000")?.usesDarkText == false, "Dark notes need light text")

        try store.saveStickyColor(id: id, colorHex: nil)
        try expect(try reopened.fetchSnapshot().stickyNotes.first?.colorHex == nil,
                   "Resetting color must restore the dynamic default appearance")
        try store.setCompleted(id: id, completed: true)
        try store.saveStickyColor(id: id, colorHex: "123456")
        let completed = try reopened.fetchSnapshot().stickyNotes.first!
        try expect(completed.colorHex == "#123456" && !completed.isVisible,
                   "A delayed color save must not reopen a completed note")
        try store.deleteTask(id: id)
        try store.saveStickyColor(id: id, colorHex: "#ABCDEF")
        try expect(try reopened.fetchSnapshot().stickyNotes.isEmpty,
                   "A delayed color save must not recreate a deleted note")
    }

    private static func testReminders(in directory: URL) throws {
        let url = directory.appendingPathComponent("legacy-p2-reminders.sqlite")
        let oldTaskID = UUID()
        try executeLegacySQL("""
            CREATE TABLE todos (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL,
                created_at REAL NOT NULL, completed_at REAL
            );
            INSERT INTO todos VALUES ('\(oldTaskID.uuidString)', '예전 미완료', 100, NULL);
            """, at: url)
        let store = try TodoStore(databaseURL: url)
        let secondConnection = try TodoStore(databaseURL: url)
        try expect(try store.fetchSnapshot().reminders.isEmpty, "Migration must not invent reminders")
        let original = try store.fetchTasks()
        let pastTime = ReminderLocalTime(year: 2000, month: 1, day: 2, hour: 9, minute: 15)!
        let futureTime = ReminderLocalTime(year: 2030, month: 12, day: 31, hour: 23, minute: 59)!
        let past = try store.setReminder(id: oldTaskID, localTime: pastTime)
        let otherTask = try store.addTask(title: "다음 알림", showAsStickyNote: true)
        let future = try store.setReminder(id: otherTask.id, localTime: futureTime)
        let pending = try secondConnection.fetchPendingReminders()
        try expect(pending.map(\.reminder) == [past, future], "Pending reads must include both overdue and future reminders across connections")
        try expect(pending.allSatisfy { !$0.isCompleted && $0.reminder.deliveredAt == nil }, "Pending candidates must describe incomplete undelivered tasks")
        try expect(try store.fetchTasks().first { $0.id == oldTaskID } == original.first, "Reminder creation must not change original task metadata")
        try store.updateTask(id: oldTaskID, title: "알림 제목 수정")
        try expect(try secondConnection.fetchPendingReminders().first?.title == "알림 제목 수정", "Reminder delivery must use the latest task title")

        let firstDeliveredAt = Date(timeIntervalSince1970: 12345)
        try secondConnection.markRemindersDelivered(generations: [past.generationID, past.generationID, UUID()], at: firstDeliveredAt)
        try store.markRemindersDelivered(generations: [past.generationID], at: firstDeliveredAt.addingTimeInterval(60))
        let deliveredSnapshot = try store.fetchSnapshot()
        try expect(deliveredSnapshot.reminders.first { $0.id == oldTaskID }?.deliveredAt == firstDeliveredAt, "Repeated acknowledgements must preserve the first delivery timestamp")
        try expect(try store.fetchPendingReminders().map(\.reminder) == [future], "Delivered reminders must not be sent again")
        try expect(try TodoStore(databaseURL: url).fetchSnapshot() == deliveredSnapshot, "Reminder components and delivery records must survive reopening")

        let replacement = try store.setReminder(id: oldTaskID, localTime: futureTime)
        try expect(replacement.generationID != past.generationID && replacement.deliveredAt == nil, "Rescheduling must start a new undelivered generation")
        try secondConnection.markRemindersDelivered(generations: [past.generationID], at: Date())
        try expect(try store.fetchSnapshot().reminders.first { $0.id == oldTaskID } == replacement, "A late acknowledgement must never consume a newly scheduled reminder")
        let beforeInvalid = try store.fetchSnapshot()
        let invalidTime = try JSONDecoder().decode(ReminderLocalTime.self, from: Data("{\"year\":2027,\"month\":2,\"day\":30,\"hour\":12,\"minute\":0}".utf8))
        do {
            try store.setReminder(id: oldTaskID, localTime: invalidTime)
            throw TestFailure(description: "Invalid reminder components were accepted")
        } catch TodoStoreError.invalidReminder {}
        do {
            try store.markRemindersDelivered(generations: [replacement.generationID], at: Date(timeIntervalSince1970: .infinity))
            throw TestFailure(description: "Invalid delivery timestamp was accepted")
        } catch TodoStoreError.invalidReminder {}
        try expect(try store.fetchSnapshot() == beforeInvalid, "Invalid reminder edits must leave all prior records unchanged")

        try secondConnection.setCompleted(id: otherTask.id, completed: true)
        try expect(try store.fetchSnapshot().reminders.allSatisfy { $0.id != otherTask.id }, "Completion from another process must remove its reminder")
        do {
            try store.setReminder(id: otherTask.id, localTime: futureTime)
            throw TestFailure(description: "Completed task accepted a new reminder")
        } catch TodoStoreError.completedTaskReminder {}
        try secondConnection.setCompleted(id: otherTask.id, completed: false)
        try expect(try store.fetchSnapshot().reminders.allSatisfy { $0.id != otherTask.id }, "Undo completion must not re-arm a reminder")

        try store.setReminder(id: otherTask.id, localTime: futureTime)
        try executeLegacySQL("UPDATE todos SET completed_at = 1000 WHERE id = '\(otherTask.id.uuidString)'", at: url)
        try expect(try store.fetchSnapshot().reminders.allSatisfy { $0.id != otherTask.id }, "An old client with foreign keys disabled must still cancel completed reminders")
        try executeLegacySQL("DELETE FROM todos WHERE id = '\(oldTaskID.uuidString)'", at: url)
        try expect(try store.fetchSnapshot().reminders.isEmpty, "An old client deleting a task must remove its reminder")
        do {
            try store.setReminder(id: oldTaskID, localTime: futureTime)
            throw TestFailure(description: "A deleted task accepted a reminder")
        } catch TodoStoreError.missingTask {}
        try store.removeReminder(id: oldTaskID)
        try store.removeReminder(id: oldTaskID)

        try store.setCompleted(id: otherTask.id, completed: false)
        let last = try store.setReminder(id: otherTask.id, localTime: pastTime)
        try store.removeReminder(id: otherTask.id)
        try store.markRemindersDelivered(generations: [last.generationID], at: Date())
        try expect(try store.fetchPendingReminders().isEmpty && store.fetchSnapshot().reminders.isEmpty, "Removal and stale delivery acknowledgement must be retry-safe")
    }

    private static func testCategories(in directory: URL) throws {
        let url = directory.appendingPathComponent("legacy-p1-categories.sqlite")
        let legacyID = UUID()
        try executeLegacySQL("""
            CREATE TABLE todos (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL,
                created_at REAL NOT NULL, completed_at REAL
            );
            INSERT INTO todos VALUES ('\(legacyID.uuidString)', '기존 할 일', 100, NULL);
            """, at: url)
        let store = try TodoStore(databaseURL: url)
        let secondConnection = try TodoStore(databaseURL: url)
        let migrated = try store.fetchSnapshot()
        let defaultCategory = migrated.categories.first(where: \.isDefault)!
        try expect(migrated.tasks == [TodoItem(id: legacyID, title: "기존 할 일", createdAt: Date(timeIntervalSince1970: 100), completedAt: nil, categoryID: defaultCategory.id)], "Category migration must preserve all legacy task data and assign the default")
        try expect(migrated.categories.count == 1 && defaultCategory.name == "기본" && defaultCategory.taskCount == 1, "Migration must provide one default category with an accurate task count")

        let work = try store.createCategory(name: "  Work  ")
        let personal = try secondConnection.createCategory(name: "개인")
        try expect(work.name == "Work", "Category names must trim outer whitespace")
        try expect(try store.fetchCategories().count == 3, "Category changes must be visible across app/widget connections")
        for invalidName in ["", " \n ", String(repeating: "가", count: 31), "줄\n바꿈"] {
            do {
                try store.createCategory(name: invalidName)
                throw TestFailure(description: "Invalid category name accepted")
            } catch TodoStoreError.invalidCategoryName {}
        }
        let boundary = try store.createCategory(name: String(repeating: "가", count: 30))
        try store.deleteCategory(id: boundary.id)
        do {
            try secondConnection.createCategory(name: "wOrK")
            throw TestFailure(description: "Case-insensitive duplicate category accepted")
        } catch TodoStoreError.duplicateCategoryName {}
        let cafe = try store.createCategory(name: "Café")
        do {
            try secondConnection.createCategory(name: "Cafe\u{301}")
            throw TestFailure(description: "Canonically equivalent duplicate category accepted")
        } catch TodoStoreError.duplicateCategoryName {}
        try store.deleteCategory(id: cafe.id)

        let task = try store.addTask(title: "분류된 할 일", categoryID: work.id, showAsStickyNote: true)
        try secondConnection.updateTask(id: task.id, title: "제목만 수정")
        try expect(try store.fetchTasks().first { $0.id == task.id }?.categoryID == work.id, "Title-only edits must preserve the assigned category")
        try store.updateTask(id: task.id, title: "제목과 분류 수정", categoryID: personal.id)
        let edited = try secondConnection.fetchTasks().first { $0.id == task.id }!
        try expect(edited.title == "제목과 분류 수정" && edited.categoryID == personal.id, "Title and category edits must persist atomically")
        try store.setCategory(id: task.id, categoryID: nil)
        try expect(try secondConnection.fetchPage(index: 0, pageSize: 8).tasks.first { $0.id == task.id }?.categoryID == defaultCategory.id, "Nil assignment must resolve to the default for app and widget")
        try store.setCategory(id: task.id, categoryID: work.id)

        let beforeRejected = try store.fetchSnapshot()
        for operation in [
            { _ = try store.addTask(title: "잘못된 분류", categoryID: UUID(), showAsStickyNote: true) },
            { try store.updateTask(id: task.id, title: "실패해야 하는 수정", categoryID: UUID()) },
            { try store.setCategory(id: task.id, categoryID: UUID()) }
        ] {
            do {
                try operation()
                throw TestFailure(description: "A deleted or unknown category was accepted")
            } catch TodoStoreError.missingCategory {}
        }
        try expect(try store.fetchSnapshot() == beforeRejected, "Stale category assignments must not partially alter tasks or create sticky notes")
        do {
            try store.renameCategory(id: work.id, name: "개인")
            throw TestFailure(description: "Renaming to an existing category was accepted")
        } catch TodoStoreError.duplicateCategoryName {}
        try store.renameCategory(id: work.id, name: "업무")
        try expect(try secondConnection.fetchSnapshot().categories.contains { $0.id == work.id && $0.name == "업무" }, "Renaming must retain category identity")
        try store.setCompleted(id: task.id, completed: true)
        let beforeDelete = try store.fetchSnapshot()
        try secondConnection.deleteCategory(id: work.id, movingTasksTo: personal.id)
        try secondConnection.deleteCategory(id: work.id)
        let afterDelete = try store.fetchSnapshot()
        let preserved = afterDelete.tasks.first { $0.id == task.id }!
        try expect(preserved.categoryID == personal.id && preserved.completedAt == beforeDelete.tasks.first { $0.id == task.id }?.completedAt, "Deleting a category must move completed tasks and preserve completion times")
        try expect(afterDelete.tasks.count == beforeDelete.tasks.count && afterDelete.stickyNotes == beforeDelete.stickyNotes, "Category deletion must preserve all task and sticky-note records")
        try expect(try TodoStore(databaseURL: url).fetchSnapshot() == afterDelete, "Categories and assignments must survive reopening")

        let concurrentFailures = ConcurrentFailures()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                try TodoStore(databaseURL: url).createCategory(name: "동시 카테고리")
            } catch TodoStoreError.duplicateCategoryName {
                // Exactly one connection wins the serialized uniqueness check.
            } catch {
                concurrentFailures.append(error)
            }
        }
        try concurrentFailures.check()
        try expect(try store.fetchCategories().filter { $0.name == "동시 카테고리" }.count == 1, "Concurrent category creation must not produce duplicates")
    }

    private static func testRequiredCategoryMigration(in directory: URL) throws {
        let url = directory.appendingPathComponent("legacy-p2-required-category.sqlite")
        let existingDefault = UUID()
        let completedID = UUID()
        let pendingID = UUID()
        let assignedID = UUID()
        let generationID = UUID()
        try executeLegacySQL("""
            CREATE TABLE categories (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, name_key TEXT NOT NULL UNIQUE);
            CREATE TABLE todos (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, created_at REAL NOT NULL, completed_at REAL,
                category_id TEXT REFERENCES categories(id) ON DELETE SET NULL
            );
            CREATE TABLE sticky_notes (
                todo_id TEXT PRIMARY KEY NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
                is_visible INTEGER NOT NULL, is_always_on_top INTEGER NOT NULL,
                position_x REAL, position_y REAL, display_id TEXT,
                width REAL, height REAL, font_size REAL, color_hex TEXT
            );
            CREATE TABLE todo_reminders (
                todo_id TEXT PRIMARY KEY NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
                generation_id TEXT NOT NULL UNIQUE, year INTEGER NOT NULL, month INTEGER NOT NULL,
                day INTEGER NOT NULL, hour INTEGER NOT NULL, minute INTEGER NOT NULL, delivered_at REAL
            );
            INSERT INTO categories VALUES ('\(existingDefault.uuidString)', '기본', '기본');
            INSERT INTO todos VALUES ('\(completedID.uuidString)', '지난 완료', 100, 200, NULL);
            INSERT INTO todos VALUES ('\(pendingID.uuidString)', '기존 알림', 300, NULL, NULL);
            INSERT INTO todos VALUES ('\(assignedID.uuidString)', '기존 분류', 400, NULL, '\(existingDefault.uuidString)');
            INSERT INTO sticky_notes VALUES ('\(pendingID.uuidString)', 1, 1, 12, 24, 'external', 300, 220, 20, '#ABCDEF');
            INSERT INTO todo_reminders VALUES ('\(pendingID.uuidString)', '\(generationID.uuidString)', 2026, 11, 11, 10, 0, 500);
            """, at: url)

        let store = try TodoStore(databaseURL: url)
        let migrated = try store.fetchSnapshot()
        try expect(migrated.categories == [TodoCategory(id: existingDefault, name: "기본", isDefault: true, taskCount: 3)], "Migration must adopt an existing default-named category without duplicating it")
        try expect(migrated.tasks.allSatisfy { $0.categoryID == existingDefault }, "Migration must categorize both historical completed tasks and incomplete tasks")
        try expect(migrated.tasks.first { $0.id == completedID } == TodoItem(id: completedID, title: "지난 완료", createdAt: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 200), categoryID: existingDefault), "Historical task dates and content must survive category migration")
        let originalNote = StickyNoteState(id: pendingID, isVisible: true, isAlwaysOnTop: true, position: StickyNotePosition(x: 12, y: 24, displayID: "external"), size: StickyNoteSize(width: 300, height: 220), fontSize: 20, colorHex: "#ABCDEF")
        try expect(migrated.stickyNotes == [originalNote], "Migration must preserve complete sticky-note state")
        try expect(migrated.reminders.count == 1 && migrated.reminders[0].generationID == generationID && migrated.reminders[0].deliveredAt == Date(timeIntervalSince1970: 500), "Migration must preserve reminder schedule and delivery generation")
        let today = DateInterval(start: Date(timeIntervalSince1970: 10_000), duration: 86_400)
        let todaySnapshot = try store.fetchSnapshot(dayRange: today)
        try expect(todaySnapshot.tasks.count == 2 && todaySnapshot.categories.first?.taskCount == 3, "Deletion counts must include completed tasks hidden by the today filter")

        try store.renameCategory(id: existingDefault, name: "생활")
        let reopened = try TodoStore(databaseURL: url)
        try expect(try reopened.fetchCategories() == [TodoCategory(id: existingDefault, name: "생활", isDefault: true, taskCount: 3)], "Renaming and reopening must preserve default identity without recreating '기본'")
        let automatic = try reopened.addTask(title: "기본 자동 배정")
        try expect(automatic.categoryID == existingDefault, "Quick-add APIs must return the category actually saved")
        try store.updateTask(id: automatic.id, title: "기본 자동 수정", categoryID: nil)
        try expect(try store.fetchTasks().first { $0.id == automatic.id }?.categoryID == existingDefault, "An omitted update category must also resolve to the default")

        let target = try store.createCategory(name: "업무")
        let beforeFailure = try store.fetchSnapshot()
        do {
            try store.deleteCategory(id: existingDefault, movingTasksTo: existingDefault)
            throw TestFailure(description: "Self category move was accepted")
        } catch TodoStoreError.invalidCategoryDestination {}
        do {
            try store.deleteCategory(id: existingDefault, movingTasksTo: UUID())
            throw TestFailure(description: "Missing category destination was accepted")
        } catch TodoStoreError.missingCategory {}
        try expect(try store.fetchSnapshot() == beforeFailure, "Invalid moves must leave every category and task unchanged")

        // Fail after the move and default change to prove the entire operation rolls back.
        try executeLegacySQL("""
            CREATE TRIGGER fail_category_delete BEFORE DELETE ON categories
                WHEN OLD.id = '\(existingDefault.uuidString)'
                BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
            """, at: url)
        do {
            try store.deleteCategory(id: existingDefault, movingTasksTo: target.id)
            throw TestFailure(description: "Injected category deletion failure was ignored")
        } catch TodoStoreError.database {}
        try expect(try store.fetchSnapshot() == beforeFailure, "A failed delete must roll back moved tasks and the replacement default")
        try executeLegacySQL("DROP TRIGGER fail_category_delete", at: url)
        try store.deleteCategory(id: existingDefault, movingTasksTo: target.id)
        let moved = try reopened.fetchSnapshot()
        try expect(moved.categories == [TodoCategory(id: target.id, name: "업무", isDefault: true, taskCount: 4)], "Deleting the default must transfer default identity and all tasks to the chosen destination")
        try expect(moved.tasks.allSatisfy { $0.categoryID == target.id } && moved.stickyNotes == beforeFailure.stickyNotes && moved.reminders == beforeFailure.reminders, "Moving on deletion must preserve all sticky notes and reminders")
        try expect(moved.tasks.first { $0.id == completedID }?.completedAt == Date(timeIntervalSince1970: 200), "Category moves must preserve completion history")
        do {
            try store.deleteCategory(id: target.id)
            throw TestFailure(description: "The last category was deleted")
        } catch TodoStoreError.lastCategory {}

        // Old app/widget processes can still issue nullable SQL while the new app is installed.
        let oldWriterID = UUID()
        try executeLegacySQL("""
            INSERT INTO todos (id, title, created_at) VALUES ('\(oldWriterID.uuidString)', '구버전 입력', 600);
            UPDATE todos SET category_id = NULL WHERE id = '\(automatic.id.uuidString)';
            """, at: url)
        try expect(try store.fetchTasks().allSatisfy { $0.categoryID == target.id }, "Legacy NULL inserts and updates must immediately inherit the surviving default")
        let legacyCategory = try store.createCategory(name: "구버전 삭제")
        try store.setCategory(id: oldWriterID, categoryID: legacyCategory.id)
        try executeLegacySQL("PRAGMA foreign_keys = OFF; DELETE FROM categories WHERE id = '\(legacyCategory.id.uuidString)'", at: url)
        try expect(try store.fetchTasks().first { $0.id == oldWriterID }?.categoryID == target.id, "Legacy deletion without foreign keys must not leave an orphaned task")
        let legacyForeignKeyCategory = try store.createCategory(name: "구버전 FK 삭제")
        try store.setCategory(id: oldWriterID, categoryID: legacyForeignKeyCategory.id)
        try executeLegacySQL("PRAGMA foreign_keys = ON; DELETE FROM categories WHERE id = '\(legacyForeignKeyCategory.id.uuidString)'", at: url)
        try expect(try store.fetchTasks().first { $0.id == oldWriterID }?.categoryID == target.id, "Legacy foreign-key SET NULL deletion must immediately assign the default")
        for invalidSQL in [
            "UPDATE todos SET category_id = '\(UUID().uuidString)' WHERE id = '\(oldWriterID.uuidString)'",
            "DELETE FROM categories WHERE id = '\(target.id.uuidString)'"
        ] {
            var rejected = false
            do { try executeLegacySQL("PRAGMA foreign_keys = OFF; \(invalidSQL)", at: url) }
            catch { rejected = true }
            try expect(rejected, "Database guards must reject unknown categories and deleting the active default, even without foreign keys")
        }

        let successor = try store.createCategory(name: "다음 기본")
        let failures = ConcurrentFailures()
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            do {
                let connection = try TodoStore(databaseURL: url)
                if worker == 0 {
                    try connection.deleteCategory(id: target.id, movingTasksTo: successor.id)
                } else {
                    for index in 0..<20 { try connection.addTask(title: "동시 기본 입력 \(index)") }
                }
            } catch { failures.append(error) }
        }
        try failures.check()
        let final = try TodoStore(databaseURL: url).fetchSnapshot()
        try expect(final.tasks.count == 25 && final.tasks.allSatisfy { $0.categoryID == successor.id }, "Concurrent creation and default deletion must keep every task in the surviving category")
        try expect(final.categories == [TodoCategory(id: successor.id, name: "다음 기본", isDefault: true, taskCount: 25)], "Exactly one default and accurate counts must survive concurrent operations and reopening")
    }

    private static func testStickyFontPersistence(in directory: URL) throws {
        let url = directory.appendingPathComponent("legacy-p1-font.sqlite")
        let id = UUID()
        try executeLegacySQL("""
            CREATE TABLE todos (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL,
                created_at REAL NOT NULL, completed_at REAL
            );
            CREATE TABLE sticky_notes (
                todo_id TEXT PRIMARY KEY NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
                is_visible INTEGER NOT NULL DEFAULT 0,
                is_always_on_top INTEGER NOT NULL DEFAULT 0,
                position_x REAL, position_y REAL, display_id TEXT, width REAL, height REAL
            );
            INSERT INTO todos VALUES ('\(id.uuidString)', '글자 크기 설정 전 포스트잇', 100, NULL);
            INSERT INTO sticky_notes VALUES ('\(id.uuidString)', 0, 1, -25, 100, 'external', 310, 230);
            """, at: url)
        let store = try TodoStore(databaseURL: url)
        let migrated = try store.fetchSnapshot()
        let originalNote = StickyNoteState(
            id: id, isVisible: false, isAlwaysOnTop: true,
            position: StickyNotePosition(x: -25, y: 100, displayID: "external"),
            size: StickyNoteSize(width: 310, height: 230)
        )
        try expect(migrated.stickyNotes == [originalNote] && migrated.stickyNoteDefaultFontSize == 17, "Font migration must preserve note geometry and state while inheriting the original 17-point default")
        let second = try store.addTask(title: "새 포스트잇", showAsStickyNote: true)
        try expect(try store.fetchSnapshot().stickyNotes.first { $0.id == second.id }?.fontSize == nil, "New notes must inherit the common font size")
        try store.saveStickyFontSize(id: second.id, fontSize: 23)
        try store.saveDefaultStickyFontSize(21)
        let customized = try store.fetchSnapshot()
        let effectiveSizes = Dictionary(uniqueKeysWithValues: customized.stickyNotes.map {
            ($0.id, $0.fontSize ?? customized.stickyNoteDefaultFontSize)
        })
        try expect(effectiveSizes[id] == 21 && effectiveSizes[second.id] == 23, "Changing the common font size must affect inheriting notes while preserving individual overrides")
        try expect(try TodoStore(databaseURL: url).fetchSnapshot() == customized, "The common size and individual overrides must both survive reopening")
        try store.saveStickyFontSize(id: second.id, fontSize: nil)
        let cleared = try store.fetchSnapshot()
        try expect(cleared.stickyNotes.allSatisfy { $0.fontSize == nil } && cleared.stickyNoteDefaultFontSize == 21, "Clearing an override must restore inheritance without changing the common setting")

        for validSize in [12.0, 32.0] {
            try store.saveDefaultStickyFontSize(validSize)
            try store.saveStickyFontSize(id: second.id, fontSize: validSize)
            let boundary = try store.fetchSnapshot()
            try expect(boundary.stickyNoteDefaultFontSize == validSize && boundary.stickyNotes.first { $0.id == second.id }?.fontSize == validSize, "Both inclusive font-size bounds must be accepted")
        }
        let beforeInvalid = try store.fetchSnapshot()
        for invalidSize in [11.0, 33.0, Double.nan, Double.infinity, -Double.infinity] {
            do {
                try store.saveStickyFontSize(id: second.id, fontSize: invalidSize)
                throw TestFailure(description: "Invalid individual font size was accepted")
            } catch TodoStoreError.invalidFontSize {}
            do {
                try store.saveDefaultStickyFontSize(invalidSize)
                throw TestFailure(description: "Invalid common font size was accepted")
            } catch TodoStoreError.invalidFontSize {}
        }
        try expect(try store.fetchSnapshot() == beforeInvalid, "Rejected font sizes must preserve all saved note and common settings")

        try store.saveStickyFontSize(id: id, fontSize: 25)
        let hidden = try store.fetchSnapshot().stickyNotes.first { $0.id == id }
        try expect(hidden?.isVisible == false && hidden?.position == originalNote.position && hidden?.size == originalNote.size && hidden?.isAlwaysOnTop == true, "Changing a hidden note's font must preserve its visibility, size, position, and pinning")
        try store.showStickyNotes(ids: [id])
        try expect(try store.fetchSnapshot().stickyNotes.first { $0.id == id }?.fontSize == 25, "Showing a note must preserve its font override")
        try store.setCompleted(id: id, completed: true)
        try store.saveStickyFontSize(id: id, fontSize: 26)
        try store.setCompleted(id: id, completed: false)
        let undone = try store.fetchSnapshot().stickyNotes.first { $0.id == id }
        try expect(undone?.fontSize == 26 && undone?.isVisible == false, "A delayed font update and completion undo must not reopen a note")
        try store.deleteTask(id: id)
        try store.saveStickyFontSize(id: id, fontSize: 20)
        try store.saveStickyFontSize(id: id, fontSize: nil)
        try expect(try store.fetchSnapshot().stickyNotes.allSatisfy { $0.id != id }, "A font update after deletion must not recreate a note")

        let legacyOverrideURL = directory.appendingPathComponent("legacy-font-override.sqlite")
        try executeLegacySQL("""
            CREATE TABLE todos (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL,
                created_at REAL NOT NULL, completed_at REAL
            );
            CREATE TABLE sticky_notes (
                todo_id TEXT PRIMARY KEY NOT NULL,
                is_visible INTEGER NOT NULL, is_always_on_top INTEGER NOT NULL,
                position_x REAL, position_y REAL, display_id TEXT, font_size REAL
            );
            INSERT INTO todos VALUES ('\(id.uuidString)', '기존 개별 글자 크기', 100, NULL);
            INSERT INTO sticky_notes VALUES ('\(id.uuidString)', 1, 0, NULL, NULL, NULL, 19);
            """, at: legacyOverrideURL)
        let legacyOverride = try TodoStore(databaseURL: legacyOverrideURL).fetchSnapshot()
        try expect(legacyOverride.stickyNotes.first?.fontSize == 19 && legacyOverride.stickyNoteDefaultFontSize == 17, "An existing individual font value must survive additive migration")
    }

    private static func testStickySizePersistence(in directory: URL) throws {
        let url = directory.appendingPathComponent("legacy-p1-size.sqlite")
        let id = UUID()
        try executeLegacySQL("""
            CREATE TABLE todos (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL,
                created_at REAL NOT NULL, completed_at REAL
            );
            CREATE TABLE sticky_notes (
                todo_id TEXT PRIMARY KEY NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
                is_visible INTEGER NOT NULL DEFAULT 0 CHECK (is_visible IN (0, 1)),
                is_always_on_top INTEGER NOT NULL DEFAULT 0 CHECK (is_always_on_top IN (0, 1)),
                position_x REAL, position_y REAL, display_id TEXT,
                CHECK ((position_x IS NULL AND position_y IS NULL)
                    OR (position_x IS NOT NULL AND position_y IS NOT NULL))
            );
            INSERT INTO todos VALUES ('\(id.uuidString)', '기존 포스트잇', 100, NULL);
            INSERT INTO sticky_notes VALUES ('\(id.uuidString)', 0, 1, -25, 100, 'external');
            """, at: url)

        let migrationFailures = ConcurrentFailures()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do {
                _ = try TodoStore(databaseURL: url).fetchSnapshot()
            } catch {
                migrationFailures.append(error)
            }
        }
        try migrationFailures.check()
        let store = try TodoStore(databaseURL: url)
        let position = StickyNotePosition(x: -25, y: 100, displayID: "external")
        let migrated = try store.fetchSnapshot()
        try expect(migrated.tasks == [TodoItem(id: id, title: "기존 포스트잇", createdAt: Date(timeIntervalSince1970: 100), completedAt: nil, categoryID: migrated.categories.first(where: \.isDefault)!.id)], "Size migration must preserve task content and assign the default category")
        try expect(migrated.stickyNotes == [StickyNoteState(id: id, isVisible: false, isAlwaysOnTop: true, position: position)], "Existing notes must preserve visibility, pinning, and position with an unset size")

        let size = StickyNoteSize(width: 310, height: 230)
        try store.saveStickySize(id: id, size: size)
        let resized = try store.fetchSnapshot()
        try expect(resized.tasks == migrated.tasks && resized.stickyNotes == [StickyNoteState(id: id, isVisible: false, isAlwaysOnTop: true, position: position, size: size)], "A delayed resize must only update size, including while hidden")
        try expect(try TodoStore(databaseURL: url).fetchSnapshot() == resized, "Saved size must survive reopening and repeated schema configuration")

        for invalidSize in [
            StickyNoteSize(width: 0, height: 100),
            StickyNoteSize(width: 100, height: -1),
            StickyNoteSize(width: .nan, height: 100),
            StickyNoteSize(width: 100, height: .infinity)
        ] {
            do {
                try store.saveStickySize(id: id, size: invalidSize)
                throw TestFailure(description: "Invalid note size was accepted")
            } catch TodoStoreError.invalidSize {}
        }
        try expect(try store.fetchSnapshot() == resized, "Invalid sizes must leave all saved state unchanged")

        let movedPosition = StickyNotePosition(x: 50, y: 75, displayID: nil)
        try store.saveStickyPosition(id: id, position: movedPosition)
        try store.showStickyNotes(ids: [id])
        let shown = try store.fetchSnapshot().stickyNotes.first
        try expect(shown?.size == size && shown?.position == movedPosition && shown?.isVisible == true, "Moving and showing a note must preserve its size")
        try store.setCompleted(id: id, completed: true)
        let lateSize = StickyNoteSize(width: 360, height: 270)
        try store.saveStickySize(id: id, size: lateSize)
        try store.setCompleted(id: id, completed: false)
        let afterUndo = try store.fetchSnapshot().stickyNotes.first
        try expect(afterUndo?.size == lateSize && afterUndo?.isVisible == false && afterUndo?.position == movedPosition, "A late resize and completion undo must never reopen a note")

        try store.deleteTask(id: id)
        try store.saveStickySize(id: id, size: size)
        let afterDelete = try store.fetchSnapshot()
        try expect(afterDelete.tasks.isEmpty && afterDelete.stickyNotes.isEmpty, "Resizing after deletion must not recreate a task or note")
        let listOnlyTask = try store.addTask(title: "포스트잇 없는 할 일")
        try store.saveStickySize(id: listOnlyTask.id, size: size)
        try expect(try store.fetchSnapshot().stickyNotes.isEmpty, "Saving size without an existing note must remain a no-op")
    }

    private static func testDayFiltering(in directory: URL) throws {
        let days = [
            (zone: "Asia/Seoul", month: 11, day: 11, hours: 24),
            (zone: "America/New_York", month: 3, day: 8, hours: 23),
            (zone: "America/New_York", month: 11, day: 1, hours: 25)
        ]
        for day in days {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: day.zone)!
            let noon = calendar.date(from: DateComponents(year: 2026, month: day.month, day: day.day, hour: 12))!
            let range = calendar.dateInterval(of: .day, for: noon)!
            try expect(range.duration == Double(day.hours * 3_600), "A local day must account for daylight saving time")

            let url = directory.appendingPathComponent("day-\(day.month)-\(day.day)-\(day.hours).sqlite")
            let store = try TodoStore(databaseURL: url)
            let start = range.start.timeIntervalSince1970
            let end = range.end.timeIntervalSince1970
            let fixtures: [(title: String, created: Double, completed: Double?, visible: Bool)] = [
                ("이전 미완료", start - 100_000, nil, true),
                ("미래 미완료", end + 100_000, nil, true),
                ("어제 완료", start - 100_000, start - 1, false),
                ("시작 시각 완료", start - 100_000, start, true),
                ("마지막 순간 완료", start - 100_000, end - 1, true),
                ("시작 시각 작성", start, end + 1, false),
                ("마지막 순간 작성", end - 1, end + 1, false),
                ("다음날 작성과 완료", end, end, false),
                ("다음날 완료", start - 100_000, end, false)
            ]
            var expectedIDs = Set<UUID>()
            for fixture in fixtures {
                let task = try store.addTask(title: fixture.title, showAsStickyNote: true)
                let completion = fixture.completed.map { String($0) } ?? "NULL"
                try executeLegacySQL("""
                    UPDATE todos SET created_at = \(fixture.created), completed_at = \(completion)
                    WHERE id = '\(task.id.uuidString)'
                    """, at: url)
                if fixture.visible { expectedIDs.insert(task.id) }
            }

            let snapshot = try store.fetchSnapshot(dayRange: range)
            try expect(Set(snapshot.tasks.map(\.id)) == expectedIDs, "Today includes all incomplete tasks and tasks completed in the half-open local day, regardless of creation time")
            try expect(Set(snapshot.stickyNotes.map(\.id)) == expectedIDs, "Snapshot note state must use the same day filter as its tasks")
            try expect(snapshot.tasks.prefix(2).allSatisfy { !$0.isCompleted }, "Filtering must preserve incomplete-first ordering")
            var pagedTasks: [TodoItem] = []
            for index in 0..<2 {
                let page = try store.fetchPage(index: index, pageSize: 2, dayRange: range)
                try expect(page.totalCount == expectedIDs.count && page.pageCount == 2, "Widget totals and pages must exclude past completions")
                pagedTasks.append(contentsOf: page.tasks)
            }
            try expect(pagedTasks == snapshot.tasks, "Filtered pagination must match snapshot ordering without gaps or duplicates")
            let lastPage = try store.fetchPage(index: 99, pageSize: 2, dayRange: range)
            try expect(lastPage.index == 1 && Set(lastPage.tasks.map(\.id)).isSubset(of: expectedIDs), "Old history page selections must clamp within today")
            let nextDay = calendar.dateInterval(of: .day, for: range.end)!
            let nextSnapshot = try store.fetchSnapshot(dayRange: nextDay)
            let nextPage = try store.fetchPage(index: 2, pageSize: 4, dayRange: nextDay)
            try expect(nextSnapshot.tasks.count == 6 && !nextSnapshot.tasks.contains { $0.title == "시작 시각 완료" }, "At local midnight yesterday's completions leave the current list")
            try expect(nextPage.index == 1 && nextPage.totalCount == 6 && nextPage.tasks.allSatisfy { !$0.isCompleted || nextDay.contains($0.completedAt!) }, "At local midnight the widget excludes yesterday and clamps its page")
            try expect(try store.fetchTasks().count == fixtures.count, "Today filtering must retain every stored task")
            try expect(try store.fetchSnapshot().tasks.count == fixtures.count, "Unfiltered snapshot callers must retain their previous behavior")
        }
    }

    private static func testWidgetCategoryOrder(in directory: URL) throws {
        let url = directory.appendingPathComponent("widget-category-order.sqlite")
        let app = try TodoStore(databaseURL: url)
        let widget = try TodoStore(databaseURL: url)
        let defaultID = try app.fetchCategories()[0].id
        let work = try app.createCategory(name: "업무")
        let olderWork = try app.addTask(title: "업무 미완료 1", categoryID: work.id)
        let newerWork = try app.addTask(title: "업무 미완료 2", categoryID: work.id)
        let defaultTask = try app.addTask(title: "기본 미완료")
        let doneWork = try app.addTask(title: "업무 완료", categoryID: work.id)
        let doneDefault = try app.addTask(title: "기본 완료")
        try executeLegacySQL("""
            UPDATE todos SET created_at = 100 WHERE id = '\(olderWork.id.uuidString)';
            UPDATE todos SET created_at = 200 WHERE id = '\(newerWork.id.uuidString)';
            UPDATE todos SET created_at = 300 WHERE id = '\(defaultTask.id.uuidString)';
            UPDATE todos SET completed_at = 400 WHERE id = '\(doneWork.id.uuidString)';
            UPDATE todos SET completed_at = 500 WHERE id = '\(doneDefault.id.uuidString)';
            """, at: url)
        let day = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86_400)

        try app.reorderCategories(ids: [work.id, defaultID])
        let firstTwo = try widget.fetchPage(index: 0, pageSize: 2, dayRange: day)
        try expect(firstTwo.tasks.map(\.id) == [newerWork.id, olderWork.id], "Apply category order before selecting the rows for each page")
        let pages = try (0..<2).map { try widget.fetchPage(index: $0, pageSize: 3, dayRange: day) }
        try expect(pages[0].tasks.map(\.id) == [newerWork.id, olderWork.id, defaultTask.id], "Category order takes priority over recency across categories")
        try expect(pages[1].tasks.map(\.id) == [doneWork.id, doneDefault.id], "Completed rows follow the same category order after unfinished rows")

        try app.reorderCategories(ids: [defaultID, work.id])
        let updated = try widget.fetchPage(index: 0, pageSize: 8, dayRange: day)
        try expect(updated.tasks.map(\.id) == [defaultTask.id, newerWork.id, olderWork.id, doneDefault.id, doneWork.id], "An open widget connection sees the new app category order")
    }

    private static func testPlannedTasks(in directory: URL) throws {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.dateInterval(of: .day, for: Date())!
        let tomorrow = calendar.dateInterval(of: .day, for: today.end)!
        let followingDay = calendar.dateInterval(of: .day, for: tomorrow.end)!
        let day = TodoPlannedDay.key(for: tomorrow.start)
        let url = directory.appendingPathComponent("planned-tasks.sqlite")
        let store = try TodoStore(databaseURL: url)
        let current = try store.addTask(title: "일반 할 일")
        let future = try store.addTask(title: "미리 적은 일", showAsStickyNote: true, plannedDay: day)

        let todaySnapshot = try store.fetchSnapshot(dayRange: today, includeUpcoming: true)
        try expect(todaySnapshot.tasks.map(\.id) == [current.id] && todaySnapshot.upcomingTasks.map(\.id) == [future.id], "Planned tasks belong only to the upcoming list before their date")
        try expect(todaySnapshot.stickyNotes.isEmpty, "Adding an upcoming task does not open a sticky note")
        let todayPage = try store.fetchPage(index: 9, pageSize: 1, dayRange: today)
        try expect(todayPage.tasks.map(\.id) == [current.id] && todayPage.totalCount == 1 && todayPage.index == 0, "Widget totals and rows both exclude future plans")

        let reopened = try TodoStore(databaseURL: url)
        try reopened.updateTask(id: future.id, title: "제목 변경", categoryID: future.categoryID)
        for range in [tomorrow, followingDay] {
            let snapshot = try reopened.fetchSnapshot(dayRange: range, includeUpcoming: true)
            let page = try reopened.fetchPage(index: 0, pageSize: 8, dayRange: range)
            try expect(snapshot.upcomingTasks.isEmpty && page.tasks == snapshot.tasks, "Due and overdue plans enter the same app and widget lists")
            try expect(page.tasks.first { $0.id == future.id }?.plannedDay == day, "The plan survives reopening and a title/category edit")
        }

        try reopened.updateTask(id: current.id, title: current.title, categoryID: current.categoryID, plannedDay: day)
        try expect(try reopened.fetchSnapshot(dayRange: today, includeUpcoming: true).upcomingTasks.count == 2, "Moving an existing task to a future date moves it into upcoming")
        try reopened.updateTask(id: future.id, title: "날짜 해제", categoryID: future.categoryID, plannedDay: nil)
        try expect(try reopened.fetchPage(index: 0, pageSize: 8, dayRange: today).tasks.map(\.id) == [future.id], "Clearing the plan immediately returns the task to today")
        try reopened.setCompleted(id: current.id, completed: true)
        try expect(try reopened.fetchSnapshot(dayRange: today, includeUpcoming: true).tasks.contains { $0.id == current.id && $0.isCompleted }, "Completing early uses the actual completion date")
        try reopened.setCompleted(id: current.id, completed: false)
        try expect(try reopened.fetchSnapshot(dayRange: today, includeUpcoming: true).upcomingTasks.map(\.id) == [current.id], "Undo restores an early completion to its planned date")
    }

    private static func testTodayOnlyPagination(in directory: URL) throws {
        let start = Date(timeIntervalSince1970: 1_794_326_400)
        let range = DateInterval(start: start, duration: 86_400)
        for pageSize in [3, 8] {
            let url = directory.appendingPathComponent("history-pages-\(pageSize).sqlite")
            let store = try TodoStore(databaseURL: url)
            var currentIDs = Set<UUID>()
            var historyIDs = Set<UUID>()
            for index in 0..<(pageSize + 1) {
                let current = try store.addTask(title: "오늘 \(index)")
                currentIDs.insert(current.id)
                let historical = try store.addTask(title: "이전 \(index)")
                historyIDs.insert(historical.id)
                // A recent creation time must not pull a past completion into today's section.
                try executeLegacySQL("""
                    UPDATE todos SET created_at = \(start.timeIntervalSince1970 + 100),
                        completed_at = \(start.timeIntervalSince1970 - Double(index + 1))
                    WHERE id = '\(historical.id.uuidString)';
                    """, at: url)
                if index > 0 {
                    try executeLegacySQL("""
                        UPDATE todos SET completed_at = \(start.timeIntervalSince1970 + Double(index))
                        WHERE id = '\(current.id.uuidString)';
                        """, at: url)
                }
            }

            let pages = try (0..<2).map { try store.fetchPage(index: $0, pageSize: pageSize, dayRange: range) }
            try expect(pages.map { $0.tasks.count } == [pageSize, 1], "Both widget sizes paginate only the current list")
            try expect(pages.allSatisfy { $0.pageCount == 2 && $0.totalCount == pageSize + 1 }, "Historical completions must not affect totals or page bounds")
            try expect(Set(pages.flatMap(\.tasks).map(\.id)) == currentIDs, "Every current task appears once with no historical rows")
            let hugePage = try store.fetchPage(index: Int.max, pageSize: Int.max, dayRange: range)
            try expect(hugePage.index == 0 && hugePage.pageCount == 1 && hugePage.tasks.count == currentIDs.count, "Large page sizes must not overflow")
            try expect(try store.fetchPage(index: -1, pageSize: pageSize, dayRange: range).index == 0, "Negative requests clamp to the first page")
            let stale = try store.fetchPage(index: 99, pageSize: pageSize, dayRange: range)
            try expect(stale.index == 1 && stale.tasks == pages[1].tasks && !stale.hasNext, "Saved history pages clamp to the last current page")

            for id in currentIDs { try store.deleteTask(id: id) }
            let emptyCurrent = try store.fetchPage(index: 99, pageSize: pageSize, dayRange: range)
            try expect(emptyCurrent.tasks.isEmpty && emptyCurrent.totalCount == 0 && emptyCurrent.index == 0 && emptyCurrent.pageCount == 1 && !emptyCurrent.hasNext, "History alone leaves one empty widget page")
            let pastRange = DateInterval(start: start.addingTimeInterval(-86_400), end: start)
            let calendarTasks = try store.fetchCompletedTasks(in: pastRange)
            try expect(Set(calendarTasks.map(\.id)) == historyIDs, "Hidden history remains available in the calendar")

            let restored = calendarTasks[0]
            try store.setCompleted(id: restored.id, completed: false)
            historyIDs.remove(restored.id)
            let currentAfterUndo = try store.fetchPage(index: 99, pageSize: pageSize, dayRange: range)
            try expect(currentAfterUndo.tasks.map(\.id) == [restored.id] && currentAfterUndo.index == 0 && currentAfterUndo.totalCount == 1, "Undo in the calendar returns a past task to the widget")
            try expect(try Set(store.fetchCompletedTasks(in: pastRange).map(\.id)) == historyIDs, "Undo updates history without deleting other records")
            try expect(try store.fetchTasks().count == pageSize + 1, "Widget filtering must never delete historical records")

        }
    }

    private static func testCompletionCalendar(in directory: URL) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let monthDate = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        let month = calendar.dateInterval(of: .month, for: monthDate)!
        let url = directory.appendingPathComponent("completion-calendar.sqlite")
        let store = try TodoStore(databaseURL: url)
        let work = try store.createCategory(name: "업무")
        let home = try store.createCategory(name: "생활")
        let fixtures: [(title: String, categoryID: UUID, completion: Date?)] = [
            ("이전 달", work.id, month.start.addingTimeInterval(-1)),
            ("월 시작", work.id, month.start),
            ("동시 완료 A", home.id, month.start.addingTimeInterval(100)),
            ("동시 완료 B", home.id, month.start.addingTimeInterval(100)),
            ("월 마지막", work.id, month.end.addingTimeInterval(-1)),
            ("다음 달", work.id, month.end),
            ("미완료", work.id, nil)
        ]
        for fixture in fixtures {
            let task = try store.addTask(title: fixture.title, categoryID: fixture.categoryID)
            let completed = fixture.completion.map { String($0.timeIntervalSince1970) } ?? "NULL"
            try executeLegacySQL("""
                UPDATE todos SET created_at = \(month.end.timeIntervalSince1970 + 100), completed_at = \(completed)
                WHERE id = '\(task.id.uuidString)'
                """, at: url)
        }
        let all = try store.fetchCompletedTasks(in: month)
        try expect(all.count == 4 && all.first?.title == "월 마지막" && all.last?.title == "월 시작", "Calendar uses completion date with inclusive start and exclusive end, independent of creation")
        try expect(all[1].id.uuidString < all[2].id.uuidString, "Equal completion timestamps use stable identity ordering")
        let workTasks = try store.fetchCompletedTasks(in: month, categoryID: work.id)
        try expect(workTasks.map(\.title) == ["월 마지막", "월 시작"], "Calendar category filtering must retain only that category's completed tasks")
        try expect(try store.fetchCompletedTasks(in: month, categoryID: UUID()).isEmpty, "A stale category selection returns no unrelated history")
        try expect(try store.fetchCompletedTasks(in: DateInterval(start: month.start, duration: 0)).isEmpty, "An empty date interval must return no completions")
    }

    private static func testAddTaskWithStickyNote(in directory: URL) throws {
        let url = directory.appendingPathComponent("add-with-sticky.sqlite")
        let store = try TodoStore(databaseURL: url)
        let defaultTask = try store.addTask(title: "기본 추가")
        let listOnlyTask = try store.addTask(title: "목록에 추가", showAsStickyNote: false)
        let listOnlySnapshot = try store.fetchSnapshot()
        try expect(Set(listOnlySnapshot.tasks.map(\.id)) == [defaultTask.id, listOnlyTask.id], "Default and explicit false must both create tasks")
        try expect(listOnlySnapshot.stickyNotes.isEmpty, "Default and explicit false must leave sticky notes empty")

        let noteTask = try store.addTask(title: "  포스트잇으로 추가  ", showAsStickyNote: true)
        let saved = try store.fetchSnapshot()
        try expect(noteTask.title == "포스트잇으로 추가" && !noteTask.isCompleted, "Adding as a sticky note must preserve title validation and incomplete state")
        let savedTask = saved.tasks.first { $0.id == noteTask.id }
        try expect(savedTask?.title == noteTask.title && savedTask?.isCompleted == false, "The sticky note must refer to the newly saved task")
        try expect(saved.stickyNotes == [StickyNoteState(id: noteTask.id, isVisible: true, isAlwaysOnTop: false, position: nil)], "A new sticky note must be visible with default position and pinning")
        try expect(try TodoStore(databaseURL: url).fetchSnapshot() == saved, "Task and sticky state must both survive reopening")

        try executeLegacySQL("""
            CREATE TRIGGER reject_new_sticky_note BEFORE INSERT ON sticky_notes
            BEGIN SELECT RAISE(ABORT, 'test sticky insert failure'); END;
            """, at: url)
        do {
            try store.addTask(title: "저장 실패 검증", showAsStickyNote: true)
            throw TestFailure(description: "Injected sticky insertion failure did not fail")
        } catch TodoStoreError.database {}
        try expect(try store.fetchSnapshot() == saved, "A failed sticky insertion must also roll back the new task")
        try executeLegacySQL("DROP TRIGGER reject_new_sticky_note", at: url)
        let retry = try store.addTask(title: "실패 후 다시 추가", showAsStickyNote: true)
        let recovered = try store.fetchSnapshot()
        try expect(recovered.tasks.count == saved.tasks.count + 1 && recovered.stickyNotes.contains { $0.id == retry.id && $0.isVisible }, "The connection must accept a complete task-and-note save after rollback")
    }

    private static func testStickyNotePersistence(in directory: URL) throws {
        let databaseURL = directory.appendingPathComponent("legacy-p0.sqlite")
        let incompleteID = UUID()
        let completedID = UUID()
        try executeLegacySQL("""
            CREATE TABLE todos (
                id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL,
                created_at REAL NOT NULL, completed_at REAL
            );
            INSERT INTO todos VALUES ('\(incompleteID.uuidString)', '기존 미완료', 100, NULL);
            INSERT INTO todos VALUES ('\(completedID.uuidString)', '기존 완료', 200, 300);
            """, at: databaseURL)
        let store = try TodoStore(databaseURL: databaseURL)
        let defaultID = try store.fetchCategories().first(where: \.isDefault)!.id
        let originalTasks = [
            TodoItem(id: incompleteID, title: "기존 미완료", createdAt: Date(timeIntervalSince1970: 100), completedAt: nil, categoryID: defaultID),
            TodoItem(id: completedID, title: "기존 완료", createdAt: Date(timeIntervalSince1970: 200), completedAt: Date(timeIntervalSince1970: 300), categoryID: defaultID)
        ]
        let migrated = try store.fetchSnapshot()
        try expect(migrated.tasks == originalTasks && migrated.stickyNotes.isEmpty, "P0 migration must preserve every existing task field")

        try store.showStickyNotes(ids: [incompleteID, completedID, UUID(), incompleteID])
        let initial = try store.fetchSnapshot().stickyNotes
        try expect(initial == [StickyNoteState(id: incompleteID, isVisible: true, isAlwaysOnTop: false, position: nil)], "Only existing incomplete tasks should get one note, with default pinning off")
        let position = StickyNotePosition(x: -123.5, y: 420, displayID: "external-display")
        try store.saveStickyPosition(id: incompleteID, position: position)
        try store.setStickyAlwaysOnTop(id: incompleteID, value: true)
        try store.hideStickyNotes(ids: [incompleteID, incompleteID, UUID()])
        let hidden = try store.fetchSnapshot()
        try expect(hidden.tasks == originalTasks && hidden.stickyNotes.first?.isVisible == false, "Hiding must preserve tasks and completion state")
        let restored = try TodoStore(databaseURL: databaseURL).fetchSnapshot()
        try expect(restored == hidden, "Reopening the store must restore hidden state, position, and pinning")
        try store.showStickyNotes(ids: [incompleteID])
        let reshown = try store.fetchSnapshot().stickyNotes.first
        try expect(reshown?.position == position && reshown?.isAlwaysOnTop == true && reshown?.isVisible == true, "Showing an existing note must preserve its position and pinning")

        for invalidPosition in [
            StickyNotePosition(x: .nan, y: 0, displayID: nil),
            StickyNotePosition(x: 0, y: .infinity, displayID: nil)
        ] {
            do {
                try store.saveStickyPosition(id: incompleteID, position: invalidPosition)
                throw TestFailure(description: "Invalid note position was accepted")
            } catch TodoStoreError.invalidPosition {}
        }
        try expect(try store.fetchSnapshot().stickyNotes.first?.position == position, "Rejected coordinates must preserve saved position")

        let second = try store.addTask(title: "두 번째 포스트잇")
        try store.showStickyNotes(ids: [second.id])
        let beforeHideAll = try store.fetchTasks()
        try store.hideAllStickyNotes()
        let hiddenAll = try store.fetchSnapshot()
        try expect(hiddenAll.tasks == beforeHideAll && hiddenAll.stickyNotes.allSatisfy { !$0.isVisible }, "Hide all must only change note visibility")

        try store.showStickyNotes(ids: [incompleteID])
        let widget = try TodoStore(databaseURL: databaseURL)
        try widget.setCompleted(id: incompleteID, completed: true)
        let latePosition = StickyNotePosition(x: 22, y: 45, displayID: nil)
        try store.saveStickyPosition(id: incompleteID, position: latePosition)
        try store.setStickyAlwaysOnTop(id: incompleteID, value: false)
        try widget.setCompleted(id: incompleteID, completed: false)
        let afterUndo = try store.fetchSnapshot().stickyNotes.first { $0.id == incompleteID }
        try expect(afterUndo?.isVisible == false && afterUndo?.position == latePosition && afterUndo?.isAlwaysOnTop == false, "Late position and pinning writes plus completion undo must not reopen a note")

        try store.showStickyNotes(ids: [incompleteID])
        // An older widget connection does not enable foreign keys or know about sticky_notes.
        try executeLegacySQL("UPDATE todos SET completed_at = 500 WHERE id = '\(incompleteID.uuidString)'", at: databaseURL)
        try expect(try store.fetchSnapshot().stickyNotes.first { $0.id == incompleteID }?.isVisible == false, "Completion by a legacy writer must hide the note")
        try executeLegacySQL("UPDATE todos SET completed_at = NULL WHERE id = '\(incompleteID.uuidString)'", at: databaseURL)
        try expect(try store.fetchSnapshot().stickyNotes.first { $0.id == incompleteID }?.isVisible == false, "Legacy completion undo must retain hidden state")
        try executeLegacySQL("DELETE FROM todos WHERE id = '\(incompleteID.uuidString)'", at: databaseURL)
        try store.saveStickyPosition(id: incompleteID, position: position)
        try store.setStickyAlwaysOnTop(id: incompleteID, value: true)
        try store.showStickyNotes(ids: [incompleteID])
        try expect(try store.fetchSnapshot().stickyNotes.allSatisfy { $0.id != incompleteID }, "Legacy deletion and stale window events must not leave or recreate note state")
        try store.deleteTask(id: second.id)
        try expect(try store.fetchSnapshot().stickyNotes.isEmpty, "Current task deletion must remove its note state")

        let bulkA = try store.addTask(title: "일괄 표시 A")
        let bulkB = try store.addTask(title: "일괄 표시 B")
        try executeLegacySQL("""
            CREATE TRIGGER reject_second_note BEFORE INSERT ON sticky_notes
            WHEN EXISTS (SELECT 1 FROM sticky_notes)
            BEGIN SELECT RAISE(ABORT, 'test rollback'); END;
            """, at: databaseURL)
        do {
            try store.showStickyNotes(ids: [bulkA.id, bulkB.id])
            throw TestFailure(description: "Injected bulk failure did not fail")
        } catch TodoStoreError.database {}
        try expect(try store.fetchSnapshot().stickyNotes.isEmpty, "Bulk show must roll back the first note if a later insert fails")
        try store.showStickyNotes(ids: [bulkA.id])
        let beforeSwap = try store.fetchSnapshot()
        do {
            try store.setStickyNoteVisibility(showing: [bulkB.id], hiding: [bulkA.id])
            throw TestFailure(description: "Injected show failure did not roll back a mixed update")
        } catch TodoStoreError.database {}
        try expect(try store.fetchSnapshot() == beforeSwap, "A failed show must roll back hides in the same update")
        try executeLegacySQL("DROP TRIGGER reject_second_note", at: databaseURL)
        try store.setStickyNoteVisibility(showing: [bulkB.id], hiding: [bulkA.id])
        let swapped = try store.fetchSnapshot()
        try expect(swapped.tasks == beforeSwap.tasks, "Visibility updates must preserve task completion")
        try expect(swapped.stickyNotes.filter(\.isVisible).map(\.id) == [bulkB.id], "One update must show and hide the requested notes")

        let size = StickyNoteSize(width: 132, height: 104)
        try store.saveStickySize(id: bulkB.id, size: size)
        try store.saveStickyPosition(id: bulkB.id, position: position)
        let completedWhileHidden = try store.addTask(title: "숨긴 동안 완료", showAsStickyNote: true)
        try store.hideAllStickyNotes()
        try store.hideAllStickyNotes()
        let reopened = try TodoStore(databaseURL: databaseURL)
        try expect(try reopened.fetchSnapshot().canRestoreStickyNotes, "An empty hide and app restart must preserve the last group")
        try reopened.setCompleted(id: completedWhileHidden.id, completed: true)
        try reopened.restoreHiddenStickyNotes()
        let restoredGroup = try reopened.fetchSnapshot()
        let visible = restoredGroup.stickyNotes.filter(\.isVisible)
        try expect(visible.map(\.id) == [bulkB.id], "Restore must only show eligible notes from the saved group")
        try expect(visible.first?.size == size && visible.first?.position == position, "Restore must preserve each note's size and position")
        try expect(!restoredGroup.canRestoreStickyNotes, "Restoring must consume the saved group")
    }

    private static func testStickyNoteConcurrency(in directory: URL) throws {
        let url = directory.appendingPathComponent("sticky-concurrent.sqlite")
        let app = try TodoStore(databaseURL: url)
        let widget = try TodoStore(databaseURL: url)
        let observer = try TodoStore(databaseURL: url)
        let task = try app.addTask(title: "동시 표시와 완료")
        try app.showStickyNotes(ids: [task.id])
        let failures = ConcurrentFailures()
        DispatchQueue.concurrentPerform(iterations: 3) { worker in
            do {
                for _ in 0..<100 {
                    switch worker {
                    case 0:
                        try widget.setCompleted(id: task.id, completed: true)
                        try widget.setCompleted(id: task.id, completed: false)
                    case 1:
                        try app.showStickyNotes(ids: [task.id])
                    default:
                        let snapshot = try observer.fetchSnapshot()
                        let completed = snapshot.tasks.first?.isCompleted == true
                        let visible = snapshot.stickyNotes.first?.isVisible == true
                        try expect(!(completed && visible), "A consistent snapshot must never show a completed task with a visible note")
                    }
                }
            } catch {
                failures.append(error)
            }
        }
        try failures.check()
        try widget.setCompleted(id: task.id, completed: true)
        try app.showStickyNotes(ids: [task.id])
        try expect(try observer.fetchSnapshot().stickyNotes.first?.isVisible == false, "A stale show selection must skip a task that completed concurrently")
    }
}
