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

    func fetchSnapshot() throws -> TodoSnapshot {
        try connection().fetchSnapshot()
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

    func showStickyNotes(ids: [UUID]) throws {
        try connection().showStickyNotes(ids: ids)
    }

    func hideStickyNotes(ids: [UUID]) throws {
        try connection().hideStickyNotes(ids: ids)
    }

    func hideAllStickyNotes() throws {
        try connection().hideAllStickyNotes()
    }

    func setStickyAlwaysOnTop(id: UUID, value: Bool) throws {
        try connection().setStickyAlwaysOnTop(id: id, value: value)
    }

    func saveStickyPosition(id: UUID, position: StickyNotePosition) throws {
        try connection().saveStickyPosition(id: id, position: position)
    }
}

@MainActor
final class TodoListModel: ObservableObject {
    @Published private(set) var snapshot = TodoSnapshot(tasks: [], stickyNotes: [])
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private let repository = TodoRepository()
    private var observer: NSObjectProtocol?
    private var refreshGeneration = 0
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private static let positionErrorMessage = "포스트잇 위치를 저장하지 못했어요. 다시 이동해 주세요."

    var onShowStickyNotes: (([UUID]) -> Void)?

    var tasks: [TodoItem] { snapshot.tasks }
    var stickyNotes: [StickyNoteState] { snapshot.stickyNotes }
    var incompleteTasks: [TodoItem] { tasks.filter { !$0.isCompleted } }
    var completedTasks: [TodoItem] { tasks.filter(\.isCompleted) }
    var visibleStickyCount: Int { stickyNotes.filter(\.isVisible).count }

    func isStickyVisible(for id: UUID) -> Bool {
        stickyNotes.contains { $0.id == id && $0.isVisible }
    }

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
            let currentSnapshot = try await repository.fetchSnapshot()
            guard generation == refreshGeneration else { return }
            snapshot = currentSnapshot
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

    func showStickyNotes(_ ids: [UUID]) async -> Bool {
        guard !ids.isEmpty else { return true }
        let succeeded = await save(reloadWidgets: false) {
            try await self.repository.showStickyNotes(ids: ids)
        }
        if succeeded { onShowStickyNotes?(ids) }
        return succeeded
    }

    func hideStickyNotes(_ ids: [UUID]) async -> Bool {
        await save(reloadWidgets: false) {
            try await self.repository.hideStickyNotes(ids: ids)
        }
    }

    func hideAllStickyNotes() async -> Bool {
        await save(reloadWidgets: false) {
            try await self.repository.hideAllStickyNotes()
        }
    }

    func setStickyAlwaysOnTop(id: UUID, value: Bool) async -> Bool {
        await save(reloadWidgets: false) {
            try await self.repository.setStickyAlwaysOnTop(id: id, value: value)
        }
    }

    func saveStickyPosition(id: UUID, position: StickyNotePosition) async {
        do {
            try await repository.saveStickyPosition(id: id, position: position)
            if errorMessage == Self.positionErrorMessage { errorMessage = nil }
        } catch {
            errorMessage = Self.positionErrorMessage
        }
    }

    func waitForPendingSave() async {
        guard isSaving else { return }
        await withCheckedContinuation { continuation in
            saveWaiters.append(continuation)
        }
    }

    private func save(reloadWidgets: Bool = true, _ operation: () async throws -> Void) async -> Bool {
        guard !isSaving else {
            errorMessage = "다른 변경을 저장하고 있어요. 잠시 후 다시 시도해 주세요."
            return false
        }
        isSaving = true
        errorMessage = nil
        defer {
            let waiters = saveWaiters
            saveWaiters.removeAll()
            isSaving = false
            for waiter in waiters { waiter.resume() }
        }
        do {
            try await operation()
            DistributedNotificationCenter.default().postNotificationName(
                TodoStore.notificationName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            if reloadWidgets { WidgetCenter.shared.reloadAllTimelines() }
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
