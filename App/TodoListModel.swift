import AppKit
import Combine
import WidgetKit

private actor TodoRepository {
    private var store: TodoStore?

    private func connection() throws -> TodoStore {
        if let store { return store }
        let opened = try TodoStore.live()
        store = opened
        return opened
    }

    func fetchTasks() throws -> [TodoItem] {
        try connection().fetchTasks()
    }

    func add(title: String) throws {
        try connection().addTask(title: title)
    }

    func update(id: UUID, title: String) throws {
        try connection().updateTask(id: id, title: title)
    }

    func setCompleted(id: UUID, completed: Bool) throws {
        try connection().setCompleted(id: id, completed: completed)
    }

    func delete(id: UUID) throws {
        try connection().deleteTask(id: id)
    }
}

@MainActor
final class TodoListModel: ObservableObject {
    @Published private(set) var tasks: [TodoItem] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private let repository = TodoRepository()
    private var observer: NSObjectProtocol?
    private var refreshGeneration = 0

    var incompleteTasks: [TodoItem] { tasks.filter { !$0.isCompleted } }
    var completedTasks: [TodoItem] { tasks.filter(\.isCompleted) }

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: TodoStore.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let currentTasks = try await repository.fetchTasks()
            guard generation == refreshGeneration else { return }
            tasks = currentTasks
            isLoading = false
        } catch {
            guard generation == refreshGeneration else { return }
            present(error)
            isLoading = false
        }
    }

    func add(title: String) async -> Bool {
        await save { try await self.repository.add(title: title) }
    }

    func update(id: UUID, title: String) async -> Bool {
        await save { try await self.repository.update(id: id, title: title) }
    }

    func setCompleted(_ task: TodoItem, completed: Bool) async {
        _ = await save { try await self.repository.setCompleted(id: task.id, completed: completed) }
    }

    func delete(_ task: TodoItem) async -> Bool {
        await save { try await self.repository.delete(id: task.id) }
    }

    private func save(_ operation: () async throws -> Void) async -> Bool {
        guard !isSaving else {
            errorMessage = "다른 변경을 저장하고 있어요. 잠시 후 다시 시도해 주세요."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await operation()
            DistributedNotificationCenter.default().postNotificationName(
                TodoStore.notificationName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            WidgetCenter.shared.reloadAllTimelines()
            await refresh()
            return true
        } catch {
            present(error)
            await refresh()
            return false
        }
    }

    private func present(_ error: Error) {
        switch error as? TodoStoreError {
        case .emptyTitle?, .missingTask?:
            errorMessage = error.localizedDescription
        case .unavailableAppGroup?:
            errorMessage = "할 일 저장 공간에 접근할 수 없어요."
        default:
            errorMessage = "할 일을 저장하거나 불러오지 못했어요. 잠시 후 다시 시도해 주세요."
        }
    }
}
