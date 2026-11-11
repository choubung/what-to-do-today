import CoreFoundation
import Foundation

struct TodoMCPInputError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum TodoMCPTool: String, CaseIterable {
    case listOpen = "list_open_tasks"
    case listCompletedToday = "list_completed_today"
    case listCompletedOn = "list_completed_on"
    case listCategories = "list_categories"
    case add = "add_task"
    case update = "update_task"
    case delete = "delete_task"
    case setCompleted = "set_task_completed"
    case setReminder = "set_task_reminder"
    case removeReminder = "remove_task_reminder"
    case move = "move_task"
    case createCategory = "create_category"
    case renameCategory = "rename_category"
    case deleteCategory = "delete_category"

    typealias Object = [String: Any]

    private enum Parameter: String {
        case taskId, categoryId, destinationCategoryId, title, category, completed, localDate, localTime, name

        var schema: Object {
            switch self {
            case .taskId:
                return ["type": "string", "format": "uuid", "description": "Task ID from a task list tool"]
            case .categoryId:
                return ["type": "string", "format": "uuid", "description": "Category ID from list_categories"]
            case .destinationCategoryId:
                return ["type": "string", "format": "uuid", "description": "ID of the category that will receive the tasks"]
            case .completed:
                return ["type": "boolean", "description": "True to complete, false to reopen"]
            case .localDate:
                return ["type": "string", "format": "date", "description": "Gregorian date on the Mac in YYYY-MM-DD format"]
            case .localTime:
                return ["type": "string", "pattern": "^[0-9]{2}:[0-9]{2}$", "description": "Mac local time in 24-hour HH:mm format"]
            case .category:
                return ["type": "string", "minLength": 1, "description": "Existing category name"]
            case .name, .title:
                return ["type": "string", "minLength": 1]
            }
        }
    }

    private var specification: (description: String, required: [Parameter], optional: [Parameter]) {
        switch self {
        case .listOpen: ("List all unfinished tasks, their reminders, and empty categories in app category order.", [], [])
        case .listCompletedToday: ("List tasks completed today on the Mac, grouped by category.", [], [])
        case .listCompletedOn: ("List tasks completed on a specific local date, grouped by category.", [.localDate], [])
        case .listCategories: ("List categories, their IDs, the default category, and task counts including history.", [], [])
        case .add: ("Add one unfinished task. Omit category to use the default category.", [.title], [.category])
        case .update: ("Change the title of an existing task.", [.taskId, .title], [])
        case .delete: ("Permanently delete a task and its reminder and sticky note.", [.taskId], [])
        case .setCompleted: ("Complete or reopen a task. Completing it clears its reminder and hides its sticky note.", [.taskId, .completed], [])
        case .setReminder: ("Set or replace the single reminder for an unfinished task, using a future date and time on the Mac.", [.taskId, .localDate, .localTime], [])
        case .removeReminder: ("Remove the reminder from a task.", [.taskId], [])
        case .move: ("Move a task to an existing category.", [.taskId, .destinationCategoryId], [])
        case .createCategory: ("Create a new category.", [.name], [])
        case .renameCategory: ("Change the name of an existing category.", [.categoryId, .name], [])
        case .deleteCategory: ("Delete a category and move all its tasks, including completion history, to another category.", [.categoryId, .destinationCategoryId], [])
        }
    }

    var isReadOnly: Bool {
        switch self {
        case .listOpen, .listCompletedToday, .listCompletedOn, .listCategories: true
        default: false
        }
    }

    var definition: Object {
        let spec = specification
        let properties = Dictionary(uniqueKeysWithValues: (spec.required + spec.optional).map { ($0.rawValue, $0.schema) })
        var annotations = ["readOnlyHint": isReadOnly, "openWorldHint": false]
        if !isReadOnly {
            annotations["destructiveHint"] = self != .add && self != .createCategory
            annotations["idempotentHint"] = self != .add && self != .createCategory && self != .setReminder
        }
        return [
            "name": rawValue,
            "description": spec.description,
            "inputSchema": [
                "type": "object", "properties": properties,
                "required": spec.required.map(\.rawValue), "additionalProperties": false
            ] as Object,
            "annotations": annotations
        ]
    }

    func validate(_ arguments: Object) throws {
        let spec = specification
        let allowed = Set((spec.required + spec.optional).map(\.rawValue))
        guard arguments.keys.allSatisfy(allowed.contains),
              spec.required.allSatisfy({ arguments[$0.rawValue] != nil }) else {
            throw TodoMCPInputError("도구의 필수 입력값과 이름을 확인해 주세요.")
        }
    }

    func execute(in store: TodoStore, arguments: Object) throws -> Object {
        let input = Inputs(values: arguments)
        switch self {
        case .listOpen, .listCompletedToday:
            guard let today = Calendar.autoupdatingCurrent.dateInterval(of: .day, for: Date()) else {
                throw TodoMCPInputError("Mac의 오늘 날짜를 확인하지 못했어요.")
            }
            return try listTasks(in: store, on: today, completed: self == .listCompletedToday)
        case .listCompletedOn:
            let localDate = try input.string(.localDate)
            let localNoon = try schedule(date: localDate, time: "12:00")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .autoupdatingCurrent
            guard let date = localNoon.date(in: calendar.timeZone),
                  let range = calendar.dateInterval(of: .day, for: date) else {
                throw TodoMCPInputError("Mac에서 해당 날짜를 확인하지 못했어요.")
            }
            return try listTasks(in: store, on: range, completed: true)
        case .listCategories:
            return ["categories": try store.fetchCategories().map(categoryPayload)]
        case .add:
            let category = arguments[Parameter.category.rawValue] == nil ? nil : try input.string(.category)
            let added = try store.addTask(title: input.string(.title), categoryName: category)
            return ["category": added.category.name, "categoryId": added.category.id.uuidString, "task": taskPayload(added.task)]
        case .update:
            let id = try input.id(.taskId)
            let title = try input.string(.title)
            try store.updateTask(id: id, title: title)
            return ["taskId": id.uuidString, "title": title]
        case .delete:
            let id = try input.id(.taskId)
            try store.deleteTask(id: id)
            return ["taskId": id.uuidString, "deleted": true]
        case .setCompleted:
            let id = try input.id(.taskId)
            let completed = try input.boolean(.completed)
            try store.setCompleted(id: id, completed: completed)
            return ["taskId": id.uuidString, "completed": completed]
        case .setReminder:
            let id = try input.id(.taskId)
            let localTime = try schedule(date: input.string(.localDate), time: input.string(.localTime))
            guard let date = localTime.date(), date > Date() else {
                throw TodoMCPInputError("알림은 Mac의 현재 시각 이후로 설정해 주세요.")
            }
            let reminder = try store.setReminder(id: id, localTime: localTime)
            return ["taskId": id.uuidString, "reminder": reminderPayload(reminder)]
        case .removeReminder:
            let id = try input.id(.taskId)
            try store.removeReminder(id: id)
            return ["taskId": id.uuidString, "reminder": NSNull()]
        case .move:
            let id = try input.id(.taskId)
            let destination = try input.id(.destinationCategoryId)
            try store.setCategory(id: id, categoryID: destination)
            return ["taskId": id.uuidString, "categoryId": destination.uuidString]
        case .createCategory:
            return ["category": try categoryPayload(store.createCategory(name: input.string(.name)))]
        case .renameCategory:
            let id = try input.id(.categoryId)
            let name = try input.string(.name).precomposedStringWithCanonicalMapping
            try store.renameCategory(id: id, name: name)
            return ["categoryId": id.uuidString, "name": name]
        case .deleteCategory:
            let id = try input.id(.categoryId)
            let destination = try input.id(.destinationCategoryId)
            try store.deleteCategory(id: id, movingTasksTo: destination)
            return ["categoryId": id.uuidString, "destinationCategoryId": destination.uuidString, "deleted": true]
        }
    }

    private func listTasks(in store: TodoStore, on day: DateInterval, completed: Bool) throws -> Object {
        let snapshot = try store.fetchSnapshot(dayRange: day)
        let tasks = Dictionary(grouping: snapshot.tasks.filter { $0.isCompleted == completed }, by: \.categoryID)
        let reminders = Dictionary(uniqueKeysWithValues: snapshot.reminders.map { ($0.id, $0) })
        let categories: [Object] = snapshot.categories.compactMap { category in
            let items = tasks[category.id] ?? []
            guard !completed || !items.isEmpty else { return nil }
            return [
                "category": category.name,
                "categoryId": category.id.uuidString,
                "isDefault": category.isDefault,
                "tasks": items.map { taskPayload($0, reminder: reminders[$0.id]) }
            ]
        }
        return ["categories": categories]
    }

    private func taskPayload(_ task: TodoItem, reminder: TodoReminder? = nil) -> Object {
        var result: Object = ["id": task.id.uuidString, "title": task.title]
        if let completedAt = task.completedAt { result["completedAt"] = completedAt.ISO8601Format() }
        if let reminder { result["reminder"] = reminderPayload(reminder) }
        return result
    }

    private func categoryPayload(_ category: TodoCategory) -> Object {
        ["id": category.id.uuidString, "name": category.name, "isDefault": category.isDefault, "taskCount": category.taskCount]
    }

    private func reminderPayload(_ reminder: TodoReminder) -> Object {
        let time = reminder.schedule
        var result: Object = [
            "localDate": String(format: "%04d-%02d-%02d", time.year, time.month, time.day),
            "localTime": String(format: "%02d:%02d", time.hour, time.minute)
        ]
        if let deliveredAt = reminder.deliveredAt { result["deliveredAt"] = deliveredAt.ISO8601Format() }
        return result
    }

    private func schedule(date: String, time: String) throws -> ReminderLocalTime {
        guard let date = date.wholeMatch(of: #/([0-9]{4})-([0-9]{2})-([0-9]{2})/#),
              let time = time.wholeMatch(of: #/([0-9]{2}):([0-9]{2})/#),
              let year = Int(date.1), let month = Int(date.2), let day = Int(date.3),
              let hour = Int(time.1), let minute = Int(time.2),
              let schedule = ReminderLocalTime(year: year, month: month, day: day, hour: hour, minute: minute) else {
            throw TodoMCPInputError("날짜와 시각은 YYYY-MM-DD와 HH:mm 형식의 유효한 Mac 현지 시각으로 입력해 주세요.")
        }
        return schedule
    }

    private struct Inputs {
        let values: Object

        func string(_ key: Parameter) throws -> String {
            guard let value = values[key.rawValue] as? String, !value.utf8.contains(0) else {
                throw TodoMCPInputError("\(key.rawValue) 값을 문자열로 입력해 주세요.")
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func id(_ key: Parameter) throws -> UUID {
            guard let id = UUID(uuidString: try string(key)) else {
                throw TodoMCPInputError("\(key.rawValue)에 조회한 항목의 ID를 입력해 주세요.")
            }
            return id
        }

        func boolean(_ key: Parameter) throws -> Bool {
            guard let value = values[key.rawValue] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw TodoMCPInputError("\(key.rawValue)에 true 또는 false를 입력해 주세요.")
            }
            return value.boolValue
        }
    }
}
