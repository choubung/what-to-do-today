import Foundation
import SQLite3

@main
private enum TodoMCPServerTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("what-to-do-today-mcp-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Tasks.sqlite")
        let appStore = try TodoStore(databaseURL: url)
        let work = try appStore.createCategory(name: "업무")
        try appStore.createCategory(name: "개인")
        let appCategories = try appStore.fetchCategories()
        let defaultID = appCategories.first { $0.isDefault }!.id
        let completed = try appStore.addTask(title: "오늘 끝낸 일", categoryID: work.id)
        try appStore.setCompleted(id: completed.id, completed: true)
        let historical = try appStore.addTask(title: "예전에 끝낸 일", categoryID: work.id)
        markHistorical(historical.id, in: url)

        var openCount = 0
        var changeCount = 0
        var server = TodoMCPServer(version: "1.0.0", openStore: {
            openCount += 1
            return try TodoStore(databaseURL: url)
        }, didChangeStore: { changeCount += 1 })

        func send(_ json: String) -> [String: Any]? {
            server.response(to: Data(json.utf8))
        }

        func call(_ tool: String, _ arguments: [String: Any] = [:]) -> [String: Any]? {
            let message: [String: Any] = [
                "jsonrpc": "2.0", "id": 4, "method": "tools/call",
                "params": ["name": tool, "arguments": arguments]
            ]
            return server.response(to: try! JSONSerialization.data(withJSONObject: message))?["result"] as? [String: Any]
        }

        func payload(_ tool: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
            guard let payload = call(tool, arguments)?["structuredContent"] as? [String: Any] else {
                preconditionFailure("Expected success from \(tool)")
            }
            return payload
        }

        func expectError(_ tool: String, _ arguments: [String: Any]) {
            let before = changeCount
            precondition(call(tool, arguments)?["isError"] as? Bool == true, "Expected failure from \(tool)")
            precondition(changeCount == before, "Failed writes must not notify observers")
        }

        precondition(send("{")?["error"] != nil)
        let listRequest = #"{"jsonrpc":"2.0","id":"list","method":"tools/list"}"#
        precondition(send(listRequest)?["error"] != nil)
        let initialized = send("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{
                "protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}
            """)?["result"] as? [String: Any]
        precondition(initialized?["protocolVersion"] as? String == "2025-06-18")
        precondition(send(listRequest)?["error"] != nil)
        precondition(send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let listing = send(listRequest)
        precondition(listing?["id"] as? String == "list")
        let tools = (listing?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        precondition(tools?.compactMap { $0["name"] as? String } == [
            "list_open_tasks", "list_completed_today", "list_completed_on", "list_categories",
            "add_task", "update_task", "delete_task", "set_task_completed",
            "set_task_reminder", "remove_task_reminder", "move_task", "create_category", "rename_category", "delete_category"
        ])
        let delete = tools?.first { $0["name"] as? String == "delete_task" }
        precondition((delete?["annotations"] as? [String: Bool])?["destructiveHint"] == true)
        precondition(openCount == 0)

        expectError("add_task", ["title": "저장하면 안 되는 일", "category": "없는 분류"])
        expectError("add_task", ["title": "   "])
        expectError("add_task", ["title": "저장하면 안 되는 일", "category": NSNull()])
        let added = payload("add_task", ["title": "  회의 자료 정리  ", "category": " 업무 "])
        precondition(added["category"] as? String == "업무")
        let defaultAdd = payload("add_task", ["title": "장보기"])
        precondition(defaultAdd["category"] as? String == "기본")
        let persisted = try appStore.fetchTasks()
        precondition(persisted.count == 4)
        precondition(persisted.first { $0.title == "회의 자료 정리" }?.categoryID == work.id)
        precondition(persisted.first { $0.title == "장보기" }?.categoryID == defaultID)
        precondition(changeCount == 2 && openCount == 1)

        let open = categories(in: call("list_open_tasks"))
        precondition(open.compactMap { $0["category"] as? String } == appCategories.map(\.name))
        precondition(Set(titles(in: open)) == ["회의 자료 정리", "장보기"])
        let done = categories(in: call("list_completed_today"))
        precondition(titles(in: done) == ["오늘 끝낸 일"])
        let historicalDate = dateString(Date(timeIntervalSince1970: 1))
        precondition(titles(in: categories(in: call("list_completed_on", ["localDate": historicalDate]))) == ["예전에 끝낸 일"])
        let taskID = (added["task"] as? [String: Any])!["id"] as! String
        let workID = work.id.uuidString
        let futureDate = dateString(Date(timeIntervalSinceNow: 172_800))
        let reminder = ["taskId": taskID, "localDate": futureDate, "localTime": "10:00"]

        expectError("update_task", ["taskId": "회의 자료 정리", "title": "잘못된 ID"])
        expectError("set_task_completed", ["taskId": taskID, "completed": 1])
        expectError("set_task_reminder", ["taskId": taskID, "localDate": "2026-02-30", "localTime": "10:00"])
        expectError("set_task_reminder", ["taskId": taskID, "localDate": historicalDate, "localTime": "10:00"])
        expectError("create_category", ["name": "업무"])
        expectError("delete_category", ["categoryId": workID, "destinationCategoryId": workID])
        let renamedTask = payload("update_task", ["taskId": taskID, "title": "  발표 자료 정리  "])
        precondition(renamedTask["title"] as? String == "발표 자료 정리")

        let created = payload("create_category", ["name": "프로젝트"])["category"] as! [String: Any]
        let projectID = created["id"] as! String
        _ = payload("rename_category", ["categoryId": projectID, "name": "기획"])
        let listed = payload("list_categories")["categories"] as! [[String: Any]]
        precondition(listed.contains { $0["id"] as? String == projectID && $0["name"] as? String == "기획" })

        _ = payload("set_task_reminder", reminder)
        let firstGeneration = try appStore.fetchPendingReminders().first?.reminder.generationID
        var changedReminder = reminder
        changedReminder["localTime"] = "11:30"
        _ = payload("set_task_reminder", changedReminder)
        _ = payload("move_task", ["taskId": taskID, "destinationCategoryId": projectID])
        let pending = try appStore.fetchPendingReminders()
        precondition(pending.count == 1 && pending[0].reminder.generationID != firstGeneration)
        let moved = categories(in: call("list_open_tasks")).first { $0["categoryId"] as? String == projectID }
        let movedTask = (moved?["tasks"] as? [[String: Any]])?.first
        precondition(movedTask?["title"] as? String == "발표 자료 정리")
        precondition((movedTask?["reminder"] as? [String: Any])?["localTime"] as? String == "11:30")

        _ = payload("remove_task_reminder", ["taskId": taskID])
        let removed = try appStore.fetchPendingReminders()
        precondition(removed.isEmpty)
        _ = payload("set_task_reminder", reminder)
        _ = payload("set_task_completed", ["taskId": taskID, "completed": true])
        expectError("set_task_reminder", reminder)
        let afterCompletion = try appStore.fetchPendingReminders()
        precondition(afterCompletion.isEmpty)
        _ = payload("set_task_completed", ["taskId": taskID, "completed": false])
        _ = payload("delete_category", ["categoryId": workID, "destinationCategoryId": projectID])
        let afterCategoryDeletion = try appStore.fetchTasks()
        let transferred = afterCategoryDeletion.filter { $0.id == completed.id || $0.id == historical.id }
        precondition(transferred.count == 2 && transferred.allSatisfy { $0.categoryID?.uuidString == projectID })
        let remainingCategories = try appStore.fetchCategories()
        precondition(remainingCategories.allSatisfy { $0.id != work.id })
        _ = payload("delete_task", ["taskId": taskID])
        let remainingTasks = try appStore.fetchTasks()
        precondition(remainingTasks.allSatisfy { $0.id.uuidString != taskID })
        precondition(changeCount == 14 && openCount == 1)
        print("TodoMCPServer tests passed")
    }

    private static func dateString(_ date: Date) -> String {
        let time = ReminderLocalTime(date: date)
        return String(format: "%04d-%02d-%02d", time.year, time.month, time.day)
    }

    private static func categories(in result: [String: Any]?) -> [[String: Any]] {
        let payload = result?["structuredContent"] as? [String: Any]
        return payload?["categories"] as? [[String: Any]] ?? []
    }

    private static func titles(in categories: [[String: Any]]) -> [String] {
        categories.flatMap { ($0["tasks"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String } }
    }

    private static func markHistorical(_ id: UUID, in url: URL) {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        precondition(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        let sql = "UPDATE todos SET completed_at = 1 WHERE id = '\(id.uuidString)'"
        precondition(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    }
}
