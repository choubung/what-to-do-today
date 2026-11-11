import Foundation
import SQLite3

enum TodoStoreError: LocalizedError {
    case emptyTitle
    case missingTask
    case unavailableAppGroup
    case invalidPageSize
    case invalidRecord
    case database(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            return "할 일을 입력해 주세요."
        case .missingTask:
            return "이 할 일을 찾을 수 없어요. 목록을 새로 확인해 주세요."
        case .unavailableAppGroup:
            return "공유 저장 공간에 접근할 수 없어요. 앱의 App Groups 서명을 확인해 주세요."
        case .invalidPageSize:
            return "목록의 페이지 크기가 올바르지 않아요."
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
    private let orderedColumns = """
        SELECT id, title, created_at, completed_at FROM todos
        ORDER BY completed_at IS NOT NULL ASC,
                 COALESCE(completed_at, created_at) DESC, id ASC
        """

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
            try execute("""
                CREATE TABLE IF NOT EXISTS todos (
                    id TEXT PRIMARY KEY NOT NULL,
                    title TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    completed_at REAL
                )
                """)
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

    /// Counting and fetching share a snapshot, including during concurrent widget updates.
    func fetchPage(index: Int, pageSize: Int) throws -> TodoPage {
        guard pageSize > 0 else { throw TodoStoreError.invalidPageSize }
        lock.lock()
        defer { lock.unlock() }

        try execute("BEGIN DEFERRED TRANSACTION")
        do {
            let count = try taskCount()
            let lastIndex = max(0, (count - 1) / pageSize)
            let clampedIndex = min(max(0, index), lastIndex)
            let tasks = try readTasks(
                sql: orderedColumns + " LIMIT ? OFFSET ?",
                pageSize: pageSize,
                offset: clampedIndex * pageSize
            )
            try execute("COMMIT")
            return TodoPage(tasks: tasks, index: clampedIndex, pageSize: pageSize, totalCount: count)
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    func addTask(title: String) throws -> TodoItem {
        let title = try validatedTitle(title)
        let task = TodoItem(id: UUID(), title: title, createdAt: Date(), completedAt: nil)
        lock.lock()
        defer { lock.unlock() }

        let statement = try prepare("INSERT INTO todos (id, title, created_at) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        try bind(task.id.uuidString, to: statement, at: 1)
        try bind(task.title, to: statement, at: 2)
        try check(sqlite3_bind_double(statement, 3, task.createdAt.timeIntervalSince1970))
        try finishWrite(statement)
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

    private func taskCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM todos")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func readTasks(sql: String, pageSize: Int? = nil, offset: Int = 0) throws -> [TodoItem] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let pageSize {
            try check(sqlite3_bind_int64(statement, 1, Int64(pageSize)))
            try check(sqlite3_bind_int64(statement, 2, Int64(offset)))
        }

        var tasks: [TodoItem] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let id = UUID(uuidString: stringColumn(statement, index: 0)) else {
                throw TodoStoreError.invalidRecord
            }
            let completedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            tasks.append(TodoItem(
                id: id,
                title: stringColumn(statement, index: 1),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                completedAt: completedAt
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
