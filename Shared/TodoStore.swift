import Foundation
import SQLite3

enum TodoStoreError: LocalizedError {
    case emptyTitle
    case missingTask
    case invalidReminder
    case completedTaskReminder
    case invalidCategoryName
    case duplicateCategoryName
    case missingCategory
    case invalidCategoryOrder
    case lastCategory
    case invalidCategoryDestination
    case unavailableAppGroup
    case invalidPageSize
    case invalidPosition
    case invalidSize
    case invalidFontSize
    case invalidColor
    case invalidRecord
    case database(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "할 일을 입력해 주세요."
        case .missingTask:
            return "이 할 일을 찾을 수 없어요. 목록을 새로 확인해 주세요."
        case .invalidCategoryName:
            return "카테고리 이름은 1–\(TodoCategory.maximumNameLength)자로 입력해 주세요."
        case .duplicateCategoryName:
            return "같은 이름의 카테고리가 이미 있어요."
        case .missingCategory:
            return "이 카테고리를 찾을 수 없어요. 다시 선택해 주세요."
        case .invalidCategoryOrder:
            return "카테고리 목록이 변경됐어요. 다시 순서를 정해 주세요."
        case .lastCategory:
            return "카테고리는 최소 하나가 필요해요. 마지막 카테고리는 삭제할 수 없어요."
        case .invalidCategoryDestination:
            return "할 일을 옮길 다른 카테고리를 선택해 주세요."
        case .invalidReminder:
            return "알림 시간을 확인해 주세요."
        case .completedTaskReminder:
            return "완료한 할 일에는 알림을 설정할 수 없어요."
        case .unavailableAppGroup:
            return "공유 저장 공간에 접근할 수 없어요. 앱의 App Groups 서명을 확인해 주세요."
        case .invalidPageSize:
            return "목록의 페이지 크기가 올바르지 않아요."
        case .invalidPosition:
            return "포스트잇 위치를 저장할 수 없어요."
        case .invalidSize:
            return "포스트잇 크기를 저장할 수 없어요."
        case .invalidFontSize:
            return "포스트잇 글자 크기를 저장할 수 없어요."
        case .invalidColor:
            return "포스트잇 색상이 올바르지 않아요. 다시 선택해 주세요."
        case .invalidRecord:
            return "저장된 할 일 정보를 읽을 수 없어요."
        case .database(let message):
            return "할 일을 저장하거나 불러오지 못했어요. \(message)"
        }
    }
}

/// Each connection is locked locally. SQLite transactions coordinate app and widget processes.
final class TodoStore: @unchecked Sendable {
    static let appGroupIdentifier = "group.com.choubung.whattodotoday"
    static let notificationName = Notification.Name("com.choubung.whattodotoday.tasksChanged")

    private var database: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let dayFilter = """
        WHERE ?1 IS NULL OR (completed_at IS NULL AND (planned_day IS NULL OR planned_day <= ?3))
            OR (completed_at >= ?1 AND completed_at < ?2)
        """
    private var orderedColumns: String {
        """
        SELECT id, title, created_at, completed_at, category_id, planned_day FROM todos
        \(dayFilter)
        ORDER BY completed_at IS NOT NULL ASC,
                 COALESCE(completed_at, created_at) DESC, id ASC
        """
    }

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            let error = databaseError()
            sqlite3_close(database)
            database = nil
            throw error
        }

        do {
            try enableWriteAheadLogging()
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA foreign_keys = ON")
            try configureSchema()
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    static func live() throws -> TodoStore {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw TodoStoreError.unavailableAppGroup
        }
        return try TodoStore(databaseURL: container.appendingPathComponent("Tasks.sqlite"))
    }

    func fetchTasks() throws -> [TodoItem] {
        lock.lock()
        defer { lock.unlock() }
        return try readTasks(sql: orderedColumns)
    }

    func fetchSnapshot(dayRange: DateInterval? = nil, includeUpcoming: Bool = false) throws -> TodoSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return try withTransaction(readOnly: true) {
            let upcomingTasks: [TodoItem]
            if includeUpcoming, let dayRange {
                upcomingTasks = try readUpcomingTasks(after: dayRange.start)
            } else {
                upcomingTasks = []
            }
            return TodoSnapshot(
                tasks: try readTasks(sql: orderedColumns, dayRange: dayRange),
                stickyNotes: try readStickyNotes(dayRange: dayRange),
                stickyNoteDefaultFontSize: try readDefaultStickyFontSize(),
                categories: try readCategories(),
                reminders: try readReminders(dayRange: includeUpcoming ? nil : dayRange),
                upcomingTasks: upcomingTasks
            )
        }
    }

    /// Counting and fetching share a snapshot, including during concurrent widget updates.
    func fetchPage(index: Int, pageSize: Int, dayRange: DateInterval? = nil) throws -> TodoPage {
        guard pageSize > 0 else { throw TodoStoreError.invalidPageSize }
        lock.lock()
        defer { lock.unlock() }

        return try withTransaction(readOnly: true) {
            let count = try taskCount(dayRange: dayRange)
            // An empty today list still has one page; old history page selections clamp here.
            let pageCount = max(1, (count - 1) / pageSize + 1)
            let clampedIndex = min(max(0, index), pageCount - 1)
            let tasks = try readTasks(
                sql: orderedColumns + " LIMIT ?4 OFFSET ?5",
                dayRange: dayRange,
                pageSize: pageSize,
                offset: clampedIndex * pageSize
            )
            return TodoPage(
                tasks: tasks, index: clampedIndex, pageSize: pageSize,
                totalCount: count
            )
        }
    }

    /// Completion time determines the calendar day; the end of the range is excluded.
    func fetchCompletedTasks(in range: DateInterval, categoryID: UUID? = nil) throws -> [TodoItem] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            SELECT id, title, created_at, completed_at, category_id, planned_day FROM todos
            WHERE completed_at >= ?1 AND completed_at < ?2
                AND (?3 IS NULL OR category_id = ?3)
            ORDER BY completed_at DESC, id ASC
            """)
        defer { sqlite3_finalize(statement) }
        try bindDayRange(range, to: statement)
        try bindCategoryID(categoryID, to: statement, at: 3)
        return try readTaskRows(statement)
    }

    @discardableResult
    func addTask(title: String, categoryID: UUID? = nil, showAsStickyNote: Bool = false, plannedDay: Int? = nil) throws -> TodoItem {
        let title = try validatedTitle(title)
        lock.lock()
        defer { lock.unlock() }

        return try withTransaction(readOnly: false) {
            let categoryID = try resolvedCategoryID(categoryID)
            return try insertTask(title: title, categoryID: categoryID, showAsStickyNote: showAsStickyNote, plannedDay: plannedDay)
        }
    }

    /// Resolves the category inside the same transaction as the insert.
    func addTask(title: String, categoryName: String?) throws -> (task: TodoItem, category: TodoCategory) {
        let title = try validatedTitle(title)
        let nameKey = try categoryName.map { categoryNameKey(try validatedCategoryName($0)) }
        lock.lock()
        defer { lock.unlock() }

        return try withTransaction(readOnly: false) {
            let categories = try readCategories()
            let category = categories.first {
                if let nameKey { return categoryNameKey($0.name) == nameKey }
                return $0.isDefault
            }
            guard let category else { throw TodoStoreError.missingCategory }
            let task = try insertTask(title: title, categoryID: category.id, showAsStickyNote: false)
            return (task, category)
        }
    }

    private func insertTask(title: String, categoryID: UUID, showAsStickyNote: Bool, plannedDay: Int? = nil) throws -> TodoItem {
        let task = TodoItem(id: UUID(), title: title, createdAt: Date(), completedAt: nil, categoryID: categoryID, plannedDay: plannedDay)
        let statement = try prepare("INSERT INTO todos (id, title, created_at, category_id, planned_day) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(task.id.uuidString, to: statement, at: 1)
        try bind(task.title, to: statement, at: 2)
        try check(sqlite3_bind_double(statement, 3, task.createdAt.timeIntervalSince1970))
        try bindCategoryID(categoryID, to: statement, at: 4)
        try bindPlannedDay(plannedDay, to: statement, at: 5)
        try finishWrite(statement)

        if showAsStickyNote, (plannedDay ?? 0) <= TodoPlannedDay.key(for: Date()) {
            let note = try prepare("INSERT INTO sticky_notes (todo_id, is_visible) VALUES (?, 1)")
            defer { sqlite3_finalize(note) }
            try bind(task.id.uuidString, to: note, at: 1)
            try finishWrite(note)
        }
        return task
    }

    func updateTask(id: UUID, title: String) throws {
        let title = try validatedTitle(title)
        lock.lock()
        defer { lock.unlock() }

        let statement = try prepare("UPDATE todos SET title = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(title, to: statement, at: 1)
        try bind(id.uuidString, to: statement, at: 2)
        try finishWrite(statement, requiresExistingTask: true)
    }

    /// Updates both fields atomically; the title-only overload preserves the existing category.
    func updateTask(id: UUID, title: String, categoryID: UUID?) throws {
        try updateTask(id: id, title: title, categoryID: categoryID, plannedDay: nil, updatePlan: false)
    }

    func updateTask(id: UUID, title: String, categoryID: UUID?, plannedDay: Int?) throws {
        try updateTask(id: id, title: title, categoryID: categoryID, plannedDay: plannedDay, updatePlan: true)
    }

    private func updateTask(id: UUID, title: String, categoryID: UUID?, plannedDay: Int?, updatePlan: Bool) throws {
        let title = try validatedTitle(title)
        lock.lock()
        defer { lock.unlock() }
        try withTransaction(readOnly: false) {
            let categoryID = try resolvedCategoryID(categoryID)
            let statement = try prepare("UPDATE todos SET title = ?1, category_id = ?2, planned_day = CASE WHEN ?4 THEN ?5 ELSE planned_day END WHERE id = ?3")
            defer { sqlite3_finalize(statement) }
            try bind(title, to: statement, at: 1)
            try bindCategoryID(categoryID, to: statement, at: 2)
            try bind(id.uuidString, to: statement, at: 3)
            try check(sqlite3_bind_int(statement, 4, updatePlan ? 1 : 0))
            try bindPlannedDay(plannedDay, to: statement, at: 5)
            try finishWrite(statement, requiresExistingTask: true)
        }
    }

    func setCategory(id: UUID, categoryID: UUID?) throws {
        lock.lock()
        defer { lock.unlock() }
        try withTransaction(readOnly: false) {
            let categoryID = try resolvedCategoryID(categoryID)
            let statement = try prepare("UPDATE todos SET category_id = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bindCategoryID(categoryID, to: statement, at: 1)
            try bind(id.uuidString, to: statement, at: 2)
            try finishWrite(statement, requiresExistingTask: true)
        }
    }

    func fetchCategories() throws -> [TodoCategory] {
        lock.lock()
        defer { lock.unlock() }
        return try readCategories()
    }

    @discardableResult
    func createCategory(name: String) throws -> TodoCategory {
        let name = try validatedCategoryName(name)
        let category = TodoCategory(id: UUID(), name: name)
        lock.lock()
        defer { lock.unlock() }
        return try withTransaction(readOnly: false) {
            try requireUniqueCategoryName(name)
            let statement = try prepare("INSERT INTO categories (id, name, name_key, sort_order) VALUES (?, ?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories))")
            defer { sqlite3_finalize(statement) }
            try bind(category.id.uuidString, to: statement, at: 1)
            try bind(name, to: statement, at: 2)
            try bind(categoryNameKey(name), to: statement, at: 3)
            try finishWrite(statement)
            return category
        }
    }

    func reorderCategories(ids: [UUID]) throws {
        lock.lock()
        defer { lock.unlock() }
        try withTransaction(readOnly: false) {
            let currentIDs = try readCategories().map(\.id)
            guard ids.count == Set(ids).count, Set(ids) == Set(currentIDs) else {
                throw TodoStoreError.invalidCategoryOrder
            }
            try writeCategoryOrder(ids)
        }
    }

    private func writeCategoryOrder(_ ids: [UUID]) throws {
        for (position, id) in ids.enumerated() {
            let statement = try prepare("UPDATE categories SET sort_order = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_int64(statement, 1, Int64(position)))
            try bind(id.uuidString, to: statement, at: 2)
            try finishWrite(statement)
        }
    }

    func renameCategory(id: UUID, name: String) throws {
        let name = try validatedCategoryName(name)
        lock.lock()
        defer { lock.unlock() }
        try withTransaction(readOnly: false) {
            try requireCategory(id)
            try requireUniqueCategoryName(name, excluding: id)
            let statement = try prepare("UPDATE categories SET name = ?, name_key = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(name, to: statement, at: 1)
            try bind(categoryNameKey(name), to: statement, at: 2)
            try bind(id.uuidString, to: statement, at: 3)
            try finishWrite(statement)
        }
    }

    func deleteCategory(id: UUID, movingTasksTo destinationID: UUID? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try withTransaction(readOnly: false) {
            let categories = try readCategories()
            // Retrying a successful deletion must not move any unrelated tasks.
            guard categories.contains(where: { $0.id == id }) else { return }
            guard categories.count > 1 else { throw TodoStoreError.lastCategory }
            let defaultID = try readDefaultCategoryID()
            let destination = destinationID ?? (defaultID == id
                ? categories.first(where: { $0.id != id })!.id : defaultID)
            guard destination != id else { throw TodoStoreError.invalidCategoryDestination }
            try requireCategory(destination)

            // Change the default first: legacy NULL writers always resolve to a surviving category.
            if defaultID == id { try writeDefaultCategoryID(destination) }
            let move = try prepare("UPDATE todos SET category_id = ? WHERE category_id = ?")
            defer { sqlite3_finalize(move) }
            try bind(destination.uuidString, to: move, at: 1)
            try bind(id.uuidString, to: move, at: 2)
            try finishWrite(move)

            let statement = try prepare("DELETE FROM categories WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, to: statement, at: 1)
            try finishWrite(statement)
        }
    }

    func deleteTask(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        let statement = try prepare("DELETE FROM todos WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        // Repeated deletion succeeds, allowing safe retries from another process.
        try finishWrite(statement)
    }

    func setCompleted(id: UUID, completed: Bool) throws {
        lock.lock()
        defer { lock.unlock() }

        let statement = try prepare("""
            UPDATE todos SET completed_at =
                CASE WHEN ? THEN COALESCE(completed_at, ?) ELSE NULL END
            WHERE id = ?
            """)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int(statement, 1, completed ? 1 : 0))
        try check(sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970))
        try bind(id.uuidString, to: statement, at: 3)
        try finishWrite(statement, requiresExistingTask: true)
    }

    func showStickyNotes(ids: [UUID]) throws {
        try updateStickyNotes(ids: ids, sql: """
            INSERT INTO sticky_notes (todo_id, is_visible)
            SELECT id, 1 FROM todos WHERE id = ? AND completed_at IS NULL
            ON CONFLICT(todo_id) DO UPDATE SET is_visible = 1
            """)
    }

    func hideStickyNotes(ids: [UUID]) throws {
        try updateStickyNotes(ids: ids, sql: "UPDATE sticky_notes SET is_visible = 0 WHERE todo_id = ?")
    }

    func hideAllStickyNotes() throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("UPDATE sticky_notes SET is_visible = 0")
    }

    func setStickyAlwaysOnTop(id: UUID, value: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("UPDATE sticky_notes SET is_always_on_top = ? WHERE todo_id = ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int(statement, 1, value ? 1 : 0))
        try bind(id.uuidString, to: statement, at: 2)
        try finishWrite(statement)
    }

    func saveStickyPosition(id: UUID, position: StickyNotePosition) throws {
        guard position.x.isFinite && position.y.isFinite else { throw TodoStoreError.invalidPosition }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            UPDATE sticky_notes SET position_x = ?, position_y = ?, display_id = ?
            WHERE todo_id = ?
            """)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, position.x))
        try check(sqlite3_bind_double(statement, 2, position.y))
        if let displayID = position.displayID {
            try bind(displayID, to: statement, at: 3)
        } else {
            try check(sqlite3_bind_null(statement, 3))
        }
        try bind(id.uuidString, to: statement, at: 4)
        try finishWrite(statement)
    }

    func saveStickySize(id: UUID, size: StickyNoteSize) throws {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw TodoStoreError.invalidSize
        }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("UPDATE sticky_notes SET width = ?, height = ? WHERE todo_id = ?")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, size.width))
        try check(sqlite3_bind_double(statement, 2, size.height))
        try bind(id.uuidString, to: statement, at: 3)
        try finishWrite(statement)
    }

    func saveStickyFontSize(id: UUID, fontSize: Double?) throws {
        if let fontSize { try validateFontSize(fontSize) }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("UPDATE sticky_notes SET font_size = ? WHERE todo_id = ?")
        defer { sqlite3_finalize(statement) }
        if let fontSize {
            try check(sqlite3_bind_double(statement, 1, fontSize))
        } else {
            try check(sqlite3_bind_null(statement, 1))
        }
        try bind(id.uuidString, to: statement, at: 2)
        try finishWrite(statement)
    }

    func saveDefaultStickyFontSize(_ fontSize: Double) throws {
        try validateFontSize(fontSize)
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            INSERT INTO app_settings (key, value) VALUES ('sticky_font_size', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, fontSize))
        try finishWrite(statement)
    }

    func saveStickyColor(id: UUID, colorHex: String?) throws {
        let normalized: String?
        if let colorHex {
            guard let color = StickyNoteColor(hex: colorHex) else { throw TodoStoreError.invalidColor }
            normalized = color.hex
        } else {
            normalized = nil
        }
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("UPDATE sticky_notes SET color_hex = ? WHERE todo_id = ?")
        defer { sqlite3_finalize(statement) }
        if let normalized {
            try bind(normalized, to: statement, at: 1)
        } else {
            try check(sqlite3_bind_null(statement, 1))
        }
        try bind(id.uuidString, to: statement, at: 2)
        // A late appearance save must never recreate a deleted note or show a hidden one.
        try finishWrite(statement)
    }

    @discardableResult
    func setReminder(id: UUID, localTime: ReminderLocalTime) throws -> TodoReminder {
        guard ReminderLocalTime(year: localTime.year, month: localTime.month, day: localTime.day,
                                hour: localTime.hour, minute: localTime.minute) != nil else {
            throw TodoStoreError.invalidReminder
        }
        let reminder = TodoReminder(id: id, schedule: localTime)
        lock.lock()
        defer { lock.unlock() }
        return try withTransaction(readOnly: false) {
            let task = try prepare("SELECT completed_at FROM todos WHERE id = ?")
            defer { sqlite3_finalize(task) }
            try bind(id.uuidString, to: task, at: 1)
            let result = sqlite3_step(task)
            if result == SQLITE_DONE { throw TodoStoreError.missingTask }
            guard result == SQLITE_ROW else { throw databaseError() }
            guard sqlite3_column_type(task, 0) == SQLITE_NULL else {
                throw TodoStoreError.completedTaskReminder
            }
            let statement = try prepare("""
                INSERT INTO todo_reminders (todo_id, generation_id, year, month, day, hour, minute, delivered_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(todo_id) DO UPDATE SET
                    generation_id = excluded.generation_id, year = excluded.year, month = excluded.month,
                    day = excluded.day, hour = excluded.hour, minute = excluded.minute, delivered_at = NULL
                """)
            defer { sqlite3_finalize(statement) }
            try bind(id.uuidString, to: statement, at: 1)
            try bind(reminder.generationID.uuidString, to: statement, at: 2)
            for (offset, component) in [localTime.year, localTime.month, localTime.day, localTime.hour, localTime.minute].enumerated() {
                try check(sqlite3_bind_int64(statement, Int32(offset + 3), Int64(component)))
            }
            try finishWrite(statement)
            return reminder
        }
    }

    func removeReminder(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("DELETE FROM todo_reminders WHERE todo_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        try finishWrite(statement)
    }

    /// Pending reminders are independent of the app's visible day range.
    func fetchPendingReminders() throws -> [TodoReminderCandidate] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare("""
            SELECT todo_id, generation_id, year, month, day, hour, minute, delivered_at, title, completed_at
            FROM todo_reminders JOIN todos ON todos.id = todo_reminders.todo_id
            WHERE completed_at IS NULL AND delivered_at IS NULL
            ORDER BY year, month, day, hour, minute, todo_id
            """)
        defer { sqlite3_finalize(statement) }
        var candidates: [TodoReminderCandidate] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            let reminder = try readReminder(statement)
            candidates.append(TodoReminderCandidate(
                taskID: reminder.id,
                title: stringColumn(statement, index: 8),
                isCompleted: sqlite3_column_type(statement, 9) != SQLITE_NULL,
                reminder: reminder
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return candidates
    }

    func markRemindersDelivered(generations: [UUID], at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw TodoStoreError.invalidReminder }
        lock.lock()
        defer { lock.unlock() }
        try withTransaction(readOnly: false) {
            let statement = try prepare("""
                UPDATE todo_reminders SET delivered_at = COALESCE(delivered_at, ?)
                WHERE generation_id = ?
                """)
            defer { sqlite3_finalize(statement) }
            for generation in Set(generations) {
                try check(sqlite3_bind_double(statement, 1, date.timeIntervalSince1970))
                try bind(generation.uuidString, to: statement, at: 2)
                try finishWrite(statement)
                try check(sqlite3_reset(statement))
            }
        }
    }

    private func readReminders(dayRange: DateInterval?) throws -> [TodoReminder] {
        let statement = try prepare("""
            SELECT todo_id, generation_id, year, month, day, hour, minute, delivered_at
            FROM todo_reminders JOIN todos ON todos.id = todo_reminders.todo_id
            \(dayFilter)
            ORDER BY todo_id
            """)
        defer { sqlite3_finalize(statement) }
        try bindListDayRange(dayRange, to: statement)
        var reminders: [TodoReminder] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            reminders.append(try readReminder(statement))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return reminders
    }

    private func readReminder(_ statement: OpaquePointer) throws -> TodoReminder {
        guard let id = UUID(uuidString: stringColumn(statement, index: 0)),
              let generation = UUID(uuidString: stringColumn(statement, index: 1)),
              let schedule = ReminderLocalTime(
                year: Int(sqlite3_column_int64(statement, 2)),
                month: Int(sqlite3_column_int64(statement, 3)),
                day: Int(sqlite3_column_int64(statement, 4)),
                hour: Int(sqlite3_column_int64(statement, 5)),
                minute: Int(sqlite3_column_int64(statement, 6))
              ) else { throw TodoStoreError.invalidRecord }
        var deliveredAt: Date?
        if sqlite3_column_type(statement, 7) != SQLITE_NULL {
            let timestamp = sqlite3_column_double(statement, 7)
            guard timestamp.isFinite else { throw TodoStoreError.invalidRecord }
            deliveredAt = Date(timeIntervalSince1970: timestamp)
        }
        return TodoReminder(id: id, generationID: generation, schedule: schedule, deliveredAt: deliveredAt)
    }

    private func configureSchema() throws {
        try withTransaction(readOnly: false) {
            let fontSizeColumn = """
                font_size REAL
                    CHECK (font_size >= \(StickyNoteTypography.minimumFontSize)
                        AND font_size <= \(StickyNoteTypography.maximumFontSize))
                """
            let colorColumn = """
                color_hex TEXT CHECK (color_hex IS NULL OR
                    (length(color_hex) = 7 AND substr(color_hex, 1, 1) = '#'
                     AND substr(color_hex, 2) NOT GLOB '*[^0-9A-F]*'))
                """
            try execute("""
                CREATE TABLE IF NOT EXISTS categories (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    name_key TEXT NOT NULL UNIQUE
                );
                CREATE TABLE IF NOT EXISTS category_settings (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    default_category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE RESTRICT
                );
                CREATE TABLE IF NOT EXISTS todos (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    completed_at REAL
                );
                CREATE TABLE IF NOT EXISTS app_settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sticky_notes (
                    todo_id TEXT PRIMARY KEY NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
                    is_visible INTEGER NOT NULL DEFAULT 0 CHECK (is_visible IN (0, 1)),
                    is_always_on_top INTEGER NOT NULL DEFAULT 0 CHECK (is_always_on_top IN (0, 1)),
                    position_x REAL,
                    position_y REAL,
                    display_id TEXT,
                    width REAL CHECK (width > 0),
                    height REAL CHECK (height > 0),
                    \(fontSizeColumn),
                    \(colorColumn),
                    CHECK ((position_x IS NULL AND position_y IS NULL)
                        OR (position_x IS NOT NULL AND position_y IS NOT NULL))
                );
                CREATE TABLE IF NOT EXISTS todo_reminders (
                    todo_id TEXT PRIMARY KEY NOT NULL REFERENCES todos(id) ON DELETE CASCADE,
                    generation_id TEXT NOT NULL UNIQUE,
                    year INTEGER NOT NULL CHECK (year BETWEEN 1 AND 9999),
                    month INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
                    day INTEGER NOT NULL CHECK (day BETWEEN 1 AND 31),
                    hour INTEGER NOT NULL CHECK (hour BETWEEN 0 AND 23),
                    minute INTEGER NOT NULL CHECK (minute BETWEEN 0 AND 59),
                    delivered_at REAL
                );
                CREATE TRIGGER IF NOT EXISTS delete_reminder_on_completion
                AFTER UPDATE OF completed_at ON todos WHEN NEW.completed_at IS NOT NULL
                BEGIN
                    DELETE FROM todo_reminders WHERE todo_id = NEW.id;
                END;
                CREATE TRIGGER IF NOT EXISTS delete_reminder_with_todo
                AFTER DELETE ON todos
                BEGIN
                    DELETE FROM todo_reminders WHERE todo_id = OLD.id;
                END;
                CREATE TRIGGER IF NOT EXISTS hide_sticky_note_on_completion
                AFTER UPDATE OF completed_at ON todos WHEN NEW.completed_at IS NOT NULL
                BEGIN
                    UPDATE sticky_notes SET is_visible = 0 WHERE todo_id = NEW.id;
                END;
                CREATE TRIGGER IF NOT EXISTS delete_sticky_note_with_todo
                AFTER DELETE ON todos
                BEGIN
                    DELETE FROM sticky_notes WHERE todo_id = OLD.id;
                END;
                """)
            let columns = try stickyNoteColumns()
            for column in ["width", "height"] where !columns.contains(column) {
                try execute("ALTER TABLE sticky_notes ADD COLUMN \(column) REAL CHECK (\(column) > 0)")
            }
            if !columns.contains("font_size") {
                try execute("ALTER TABLE sticky_notes ADD COLUMN \(fontSizeColumn)")
            }
            if !columns.contains("color_hex") {
                try execute("ALTER TABLE sticky_notes ADD COLUMN \(colorColumn)")
            }
            if try !tableColumns("todos").contains("category_id") {
                try execute("ALTER TABLE todos ADD COLUMN category_id TEXT REFERENCES categories(id) ON DELETE SET NULL")
            }
            if try !tableColumns("todos").contains("planned_day") {
                try execute("ALTER TABLE todos ADD COLUMN planned_day INTEGER")
            }
            try execute("CREATE INDEX IF NOT EXISTS todos_category ON todos(category_id)")
            try execute("CREATE INDEX IF NOT EXISTS todos_completion_date ON todos(completed_at DESC, id ASC)")
            try configureRequiredCategories()
            if try !tableColumns("categories").contains("sort_order") {
                try execute("ALTER TABLE categories ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0")
                // Retain the previous default-first/name ordering on the first upgrade.
                try writeCategoryOrder(readCategories().map(\.id))
            }
        }
    }

    /// Runs inside the schema transaction, including when app and widget first open together.
    private func configureRequiredCategories() throws {
        let existing = try prepare("""
            SELECT c.id FROM categories c JOIN category_settings s
                ON c.id = s.default_category_id WHERE s.singleton = 1
            """)
        defer { sqlite3_finalize(existing) }
        let result = sqlite3_step(existing)
        if result == SQLITE_DONE {
            // Reuse a user's existing '기본' category instead of duplicating or renaming it.
            let named = try prepare("SELECT id FROM categories WHERE name_key = '기본'")
            defer { sqlite3_finalize(named) }
            let namedResult = sqlite3_step(named)
            let defaultID: UUID
            if namedResult == SQLITE_ROW {
                guard let id = UUID(uuidString: stringColumn(named, index: 0)) else {
                    throw TodoStoreError.invalidRecord
                }
                defaultID = id
            } else if namedResult == SQLITE_DONE {
                defaultID = UUID()
                let insert = try prepare("INSERT INTO categories (id, name, name_key) VALUES (?, '기본', '기본')")
                defer { sqlite3_finalize(insert) }
                try bind(defaultID.uuidString, to: insert, at: 1)
                try finishWrite(insert)
            } else {
                throw databaseError()
            }
            try writeDefaultCategoryID(defaultID)
        } else if result != SQLITE_ROW {
            throw databaseError()
        }

        // Only the category changes; completion, reminder and sticky-note columns remain intact.
        try execute("""
            UPDATE todos SET category_id = (SELECT default_category_id FROM category_settings WHERE singleton = 1)
                WHERE category_id IS NULL OR category_id NOT IN (SELECT id FROM categories);

            CREATE TRIGGER IF NOT EXISTS require_valid_category_on_insert
            BEFORE INSERT ON todos
            WHEN NEW.category_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categories WHERE id = NEW.category_id)
            BEGIN SELECT RAISE(ABORT, 'Unknown todo category'); END;
            CREATE TRIGGER IF NOT EXISTS require_valid_category_on_update
            BEFORE UPDATE OF category_id ON todos
            WHEN NEW.category_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categories WHERE id = NEW.category_id)
            BEGIN SELECT RAISE(ABORT, 'Unknown todo category'); END;

            CREATE TRIGGER IF NOT EXISTS assign_default_category_on_insert
            AFTER INSERT ON todos WHEN NEW.category_id IS NULL
            BEGIN
                UPDATE todos SET category_id = (SELECT default_category_id FROM category_settings WHERE singleton = 1)
                    WHERE id = NEW.id;
            END;
            CREATE TRIGGER IF NOT EXISTS assign_default_category_on_update
            AFTER UPDATE OF category_id ON todos WHEN NEW.category_id IS NULL
            BEGIN
                UPDATE todos SET category_id = (SELECT default_category_id FROM category_settings WHERE singleton = 1)
                    WHERE id = NEW.id;
            END;

            CREATE TRIGGER IF NOT EXISTS protect_default_category
            BEFORE DELETE ON categories
            WHEN OLD.id = (SELECT default_category_id FROM category_settings WHERE singleton = 1)
            BEGIN SELECT RAISE(ABORT, 'Choose a replacement default category before deleting'); END;
            CREATE TRIGGER IF NOT EXISTS move_tasks_after_legacy_category_delete
            AFTER DELETE ON categories
            BEGIN
                UPDATE todos SET category_id = (SELECT default_category_id FROM category_settings WHERE singleton = 1)
                    WHERE category_id = OLD.id;
            END;
            """)
    }

    private func stickyNoteColumns() throws -> Set<String> {
        try tableColumns("sticky_notes")
    }

    private func tableColumns(_ table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            columns.insert(stringColumn(statement, index: 1))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return columns
    }

    private func updateStickyNotes(ids: [UUID], sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try withTransaction(readOnly: false) {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            for id in Set(ids) {
                try bind(id.uuidString, to: statement, at: 1)
                try finishWrite(statement)
                try check(sqlite3_reset(statement))
            }
        }
    }

    private func readStickyNotes(dayRange: DateInterval?) throws -> [StickyNoteState] {
        let statement = try prepare("""
            SELECT todo_id, is_visible, is_always_on_top, position_x, position_y, display_id, width, height, font_size, color_hex
            FROM sticky_notes JOIN todos ON todos.id = sticky_notes.todo_id
            \(dayFilter)
            ORDER BY todo_id
            """)
        defer { sqlite3_finalize(statement) }
        try bindListDayRange(dayRange, to: statement)
        var notes: [StickyNoteState] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = UUID(uuidString: stringColumn(statement, index: 0)) else {
                throw TodoStoreError.invalidRecord
            }
            var position: StickyNotePosition?
            if sqlite3_column_type(statement, 3) != SQLITE_NULL {
                let x = sqlite3_column_double(statement, 3)
                let y = sqlite3_column_double(statement, 4)
                guard x.isFinite, y.isFinite, sqlite3_column_type(statement, 4) != SQLITE_NULL else {
                    throw TodoStoreError.invalidRecord
                }
                position = StickyNotePosition(
                    x: x, y: y,
                    displayID: sqlite3_column_type(statement, 5) == SQLITE_NULL
                        ? nil : stringColumn(statement, index: 5)
                )
            }
            var size: StickyNoteSize?
            if sqlite3_column_type(statement, 6) != SQLITE_NULL || sqlite3_column_type(statement, 7) != SQLITE_NULL {
                let width = sqlite3_column_double(statement, 6)
                let height = sqlite3_column_double(statement, 7)
                guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                    throw TodoStoreError.invalidRecord
                }
                size = StickyNoteSize(width: width, height: height)
            }
            var fontSize: Double?
            if sqlite3_column_type(statement, 8) != SQLITE_NULL {
                let savedFontSize = sqlite3_column_double(statement, 8)
                do {
                    try validateFontSize(savedFontSize)
                } catch {
                    throw TodoStoreError.invalidRecord
                }
                fontSize = savedFontSize
            }
            var colorHex: String?
            if sqlite3_column_type(statement, 9) != SQLITE_NULL {
                let savedColor = stringColumn(statement, index: 9)
                guard let color = StickyNoteColor(hex: savedColor), color.hex == savedColor else {
                    throw TodoStoreError.invalidRecord
                }
                colorHex = color.hex
            }
            notes.append(StickyNoteState(
                id: id,
                isVisible: sqlite3_column_int(statement, 1) != 0,
                isAlwaysOnTop: sqlite3_column_int(statement, 2) != 0,
                position: position,
                size: size,
                fontSize: fontSize,
                colorHex: colorHex
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return notes
    }

    private func readDefaultStickyFontSize() throws -> Double {
        let statement = try prepare("SELECT value FROM app_settings WHERE key = 'sticky_font_size'")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return StickyNoteTypography.defaultFontSize }
        guard result == SQLITE_ROW else { throw databaseError() }
        let fontSize = sqlite3_column_double(statement, 0)
        do {
            try validateFontSize(fontSize)
        } catch {
            throw TodoStoreError.invalidRecord
        }
        return fontSize
    }

    private func validateFontSize(_ fontSize: Double) throws {
        guard fontSize.isFinite,
              fontSize >= StickyNoteTypography.minimumFontSize,
              fontSize <= StickyNoteTypography.maximumFontSize else {
            throw TodoStoreError.invalidFontSize
        }
    }

    private func withTransaction<Value>(readOnly: Bool, _ operation: () throws -> Value) throws -> Value {
        try execute(readOnly ? "BEGIN DEFERRED TRANSACTION" : "BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try operation()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func enableWriteAheadLogging() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            let result = sqlite3_exec(database, "PRAGMA journal_mode = WAL", nil, nil, nil)
            if result == SQLITE_OK { return }
            // Journal-mode lock upgrades need an explicit retry during concurrent first opens.
            guard (result == SQLITE_BUSY || result == SQLITE_LOCKED),
                  ProcessInfo.processInfo.systemUptime < deadline else {
                throw databaseError()
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func validatedTitle(_ title: String) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TodoStoreError.emptyTitle }
        return title
    }

    private func validatedCategoryName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= TodoCategory.maximumNameLength,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw TodoStoreError.invalidCategoryName
        }
        return name
    }

    private func categoryNameKey(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func requireUniqueCategoryName(_ name: String, excluding id: UUID? = nil) throws {
        let statement = try prepare("SELECT id FROM categories WHERE name_key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(categoryNameKey(name), to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW {
            guard stringColumn(statement, index: 0) == id?.uuidString else {
                throw TodoStoreError.duplicateCategoryName
            }
        } else if result != SQLITE_DONE {
            throw databaseError()
        }
    }

    private func requireCategory(_ id: UUID?) throws {
        guard let id else { return }
        let statement = try prepare("SELECT 1 FROM categories WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { throw TodoStoreError.missingCategory }
        guard result == SQLITE_ROW else { throw databaseError() }
    }

    private func readDefaultCategoryID() throws -> UUID {
        let statement = try prepare("SELECT default_category_id FROM category_settings WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = UUID(uuidString: stringColumn(statement, index: 0)) else {
            throw TodoStoreError.invalidRecord
        }
        return id
    }

    private func writeDefaultCategoryID(_ id: UUID) throws {
        let statement = try prepare("""
            INSERT INTO category_settings (singleton, default_category_id) VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET default_category_id = excluded.default_category_id
            """)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        try finishWrite(statement)
    }

    private func resolvedCategoryID(_ id: UUID?) throws -> UUID {
        let resolved = try id ?? readDefaultCategoryID()
        try requireCategory(resolved)
        return resolved
    }

    private func readCategories() throws -> [TodoCategory] {
        let statement = try prepare("""
            SELECT c.id, c.name, c.id = s.default_category_id,
                (SELECT COUNT(*) FROM todos t WHERE t.category_id = c.id)
            FROM categories c JOIN category_settings s ON s.singleton = 1
            ORDER BY c.sort_order, (c.id = s.default_category_id) DESC, c.name_key, c.id
            """)
        defer { sqlite3_finalize(statement) }
        var categories: [TodoCategory] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = UUID(uuidString: stringColumn(statement, index: 0)) else {
                throw TodoStoreError.invalidRecord
            }
            categories.append(TodoCategory(
                id: id, name: stringColumn(statement, index: 1),
                isDefault: sqlite3_column_int(statement, 2) != 0,
                taskCount: Int(sqlite3_column_int64(statement, 3))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return categories
    }

    private func bindCategoryID(_ id: UUID?, to statement: OpaquePointer, at index: Int32) throws {
        if let id {
            try bind(id.uuidString, to: statement, at: index)
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func readUpcomingTasks(after date: Date) throws -> [TodoItem] {
        let statement = try prepare("""
            SELECT id, title, created_at, completed_at, category_id, planned_day FROM todos
            WHERE completed_at IS NULL AND planned_day > ?1
            ORDER BY planned_day ASC, created_at DESC, id ASC
            """)
        defer { sqlite3_finalize(statement) }
        try bindPlannedDay(TodoPlannedDay.key(for: date), to: statement, at: 1)
        return try readTaskRows(statement)
    }

    private func taskCount(dayRange: DateInterval?) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM todos \(dayFilter)")
        defer { sqlite3_finalize(statement) }
        try bindListDayRange(dayRange, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func readTasks(sql: String, dayRange: DateInterval? = nil, pageSize: Int? = nil, offset: Int = 0) throws -> [TodoItem] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindListDayRange(dayRange, to: statement)
        if let pageSize {
            try check(sqlite3_bind_int64(statement, 4, Int64(pageSize)))
            try check(sqlite3_bind_int64(statement, 5, Int64(offset)))
        }
        return try readTaskRows(statement)
    }

    private func readTaskRows(_ statement: OpaquePointer) throws -> [TodoItem] {
        var tasks: [TodoItem] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = UUID(uuidString: stringColumn(statement, index: 0)) else {
                throw TodoStoreError.invalidRecord
            }
            let completedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            guard let categoryID = UUID(uuidString: stringColumn(statement, index: 4)) else {
                throw TodoStoreError.invalidRecord
            }
            tasks.append(TodoItem(
                id: id,
                title: stringColumn(statement, index: 1),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                completedAt: completedAt,
                categoryID: categoryID,
                plannedDay: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 5))
            ))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw databaseError() }
        return tasks
    }

    private func stringColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        let length = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        guard let statement else { throw databaseError() }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withCString { bytes in
            sqlite3_bind_text64(statement, index, bytes, UInt64(value.utf8.count), transient, UInt8(SQLITE_UTF8))
        }
        try check(result)
    }

    private func bindPlannedDay(_ day: Int?, to statement: OpaquePointer, at index: Int32) throws {
        if let day {
            try check(sqlite3_bind_int64(statement, index, Int64(day)))
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    private func bindListDayRange(_ range: DateInterval?, to statement: OpaquePointer) throws {
        try bindDayRange(range, to: statement)
        try bindPlannedDay(range.map { TodoPlannedDay.key(for: $0.start) }, to: statement, at: 3)
    }

    private func bindDayRange(_ dayRange: DateInterval?, to statement: OpaquePointer) throws {
        if let dayRange {
            try check(sqlite3_bind_double(statement, 1, dayRange.start.timeIntervalSince1970))
            try check(sqlite3_bind_double(statement, 2, dayRange.end.timeIntervalSince1970))
        } else {
            try check(sqlite3_bind_null(statement, 1))
            try check(sqlite3_bind_null(statement, 2))
        }
    }

    private func finishWrite(_ statement: OpaquePointer, requiresExistingTask: Bool = false) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        if requiresExistingTask && sqlite3_changes(database) == 0 {
            throw TodoStoreError.missingTask
        }
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw databaseError() }
    }

    private func databaseError() -> TodoStoreError {
        guard let database else { return .database("저장 공간을 열 수 없어요.") }
        return .database(String(cString: sqlite3_errmsg(database)))
    }
}
