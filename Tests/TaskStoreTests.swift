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
        try testStickyNotePersistence(in: directory)
        try testStickyNoteConcurrency(in: directory)
        try testAddTaskWithStickyNote(in: directory)
        try testDayFiltering(in: directory)
        try testStickySizePersistence(in: directory)
        try testStickyFontPersistence(in: directory)
        try testStickyColorPersistence(in: directory)
        try testCategories(in: directory)
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
        try expect(migrated.tasks == [TodoItem(id: legacyID, title: "기존 할 일", createdAt: Date(timeIntervalSince1970: 100), completedAt: nil)], "Category migration must preserve all legacy task data as uncategorized")
        try expect(migrated.categories.isEmpty, "Migration must not invent user categories")

        let work = try store.createCategory(name: "  Work  ")
        let personal = try secondConnection.createCategory(name: "개인")
        try expect(work.name == "Work", "Category names must trim outer whitespace")
        try expect(try store.fetchCategories().count == 2, "Category changes must be visible across app/widget connections")
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
        try expect(try secondConnection.fetchPage(index: 0, pageSize: 8).tasks.first { $0.id == task.id }?.categoryID == nil, "Widgets must read uncategorized assignments")
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
        try expect(try secondConnection.fetchSnapshot().categories.contains(TodoCategory(id: work.id, name: "업무")), "Renaming must retain category identity")
        try store.setCompleted(id: task.id, completed: true)
        let beforeDelete = try store.fetchSnapshot()
        try secondConnection.deleteCategory(id: work.id)
        try secondConnection.deleteCategory(id: work.id)
        let afterDelete = try store.fetchSnapshot()
        let preserved = afterDelete.tasks.first { $0.id == task.id }!
        try expect(preserved.categoryID == nil && preserved.completedAt == beforeDelete.tasks.first { $0.id == task.id }?.completedAt, "Deleting a category must preserve completed tasks and completion times")
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
        try expect(migrated.tasks == [TodoItem(id: id, title: "기존 포스트잇", createdAt: Date(timeIntervalSince1970: 100), completedAt: nil)], "Size migration must preserve every task field")
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
                ("시작 시각 작성", start, end + 1, true),
                ("마지막 순간 작성", end - 1, end + 1, true),
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
            try expect(Set(snapshot.tasks.map(\.id)) == expectedIDs, "Today includes all incomplete tasks and completed tasks created or completed in the half-open local day")
            try expect(Set(snapshot.stickyNotes.map(\.id)) == expectedIDs, "Snapshot note state must use the same day filter as its tasks")
            try expect(snapshot.tasks.prefix(2).allSatisfy { !$0.isCompleted }, "Filtering must preserve incomplete-first ordering")
            var pagedTasks: [TodoItem] = []
            for index in 0..<3 {
                let page = try store.fetchPage(index: index, pageSize: 2, dayRange: range)
                try expect(page.totalCount == expectedIDs.count && page.pageCount == 3, "Widget count and page bounds must use the filtered rows")
                pagedTasks.append(contentsOf: page.tasks)
            }
            try expect(pagedTasks == snapshot.tasks, "Filtered pagination must match snapshot ordering without gaps or duplicates")
            try expect(try store.fetchPage(index: 99, pageSize: 2, dayRange: range).index == 2, "Page clamping must use the filtered count")
            try expect(try store.fetchTasks().count == fixtures.count, "Today filtering must retain every stored task")
            try expect(try store.fetchSnapshot().tasks.count == fixtures.count, "Unfiltered snapshot callers must retain their previous behavior")
        }
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
        let originalTasks = [
            TodoItem(id: incompleteID, title: "기존 미완료", createdAt: Date(timeIntervalSince1970: 100), completedAt: nil),
            TodoItem(id: completedID, title: "기존 완료", createdAt: Date(timeIntervalSince1970: 200), completedAt: Date(timeIntervalSince1970: 300))
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
        try executeLegacySQL("DROP TRIGGER reject_second_note", at: databaseURL)
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
