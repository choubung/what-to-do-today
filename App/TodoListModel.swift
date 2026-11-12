import AppKit
import Combine
import WidgetKit

private actor TodoRepository {
    private var store: TodoStore?

    init(store: TodoStore? = nil) { self.store = store }

    private func connection() throws -> TodoStore {
        if let store { return store }
        let opened = try TodoStore.live()
        store = opened
        return opened
    }

    func fetchSnapshot() throws -> TodoSnapshot {
        try connection().fetchSnapshot(dayRange: Calendar.autoupdatingCurrent.dateInterval(of: .day, for: Date()), includeUpcoming: true)
    }

    func fetchCompletedTasks(in range: DateInterval, categoryID: UUID?) throws -> [TodoItem] {
        try connection().fetchCompletedTasks(in: range, categoryID: categoryID)
    }

    func add(title: String, categoryID: UUID?, showAsStickyNote: Bool, plannedDay: Int?) throws {
        try connection().addTask(title: title, categoryID: categoryID, showAsStickyNote: showAsStickyNote, plannedDay: plannedDay)
    }

    func update(id: UUID, title: String) throws {
        try connection().updateTask(id: id, title: title)
    }

    func update(id: UUID, title: String, categoryID: UUID?, plannedDay: Int?) throws {
        try connection().updateTask(id: id, title: title, categoryID: categoryID, plannedDay: plannedDay)
    }

    func setCategory(id: UUID, categoryID: UUID?) throws {
        try connection().setCategory(id: id, categoryID: categoryID)
    }

    func createCategory(name: String) throws -> UUID {
        try connection().createCategory(name: name).id
    }

    func reorderCategories(ids: [UUID]) throws {
        try connection().reorderCategories(ids: ids)
    }

    func renameCategory(id: UUID, name: String) throws {
        try connection().renameCategory(id: id, name: name)
    }

    func deleteCategory(id: UUID, movingTasksTo destinationID: UUID?) throws {
        try connection().deleteCategory(id: id, movingTasksTo: destinationID)
    }

    func setReminder(id: UUID, localTime: ReminderLocalTime) throws {
        try connection().setReminder(id: id, localTime: localTime)
    }

    func removeReminder(id: UUID) throws {
        try connection().removeReminder(id: id)
    }

    func loadPendingReminders() throws -> [TodoReminderCandidate] {
        try connection().fetchPendingReminders()
    }

    func markRemindersDelivered(generations: [UUID], at date: Date) throws {
        try connection().markRemindersDelivered(generations: generations, at: date)
    }

    func setCompleted(id: UUID, completed: Bool) throws {
        try connection().setCompleted(id: id, completed: completed)
    }

    func delete(id: UUID) throws {
        try connection().deleteTask(id: id)
    }

    func setStickyNoteVisibility(showing: [UUID], hiding: [UUID]) throws {
        try connection().setStickyNoteVisibility(showing: showing, hiding: hiding)
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

    func saveStickySize(id: UUID, size: StickyNoteSize) throws {
        try connection().saveStickySize(id: id, size: size)
    }

    func saveStickyFontSize(id: UUID, fontSize: Double?) throws {
        try connection().saveStickyFontSize(id: id, fontSize: fontSize)
    }

    func saveDefaultStickyFontSize(_ fontSize: Double) throws {
        try connection().saveDefaultStickyFontSize(fontSize)
    }

    func saveCategoryStickyColor(id: UUID, colorHex: String?) throws {
        try connection().saveCategoryStickyColor(id: id, colorHex: colorHex)
    }

    func saveStickyColor(id: UUID, colorHex: String?) throws {
        try connection().saveStickyColor(id: id, colorHex: colorHex)
    }
}

@MainActor
final class TodoListModel: ObservableObject {
    @Published private(set) var snapshot = TodoSnapshot(tasks: [], stickyNotes: [])
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    @Published private(set) var completionHistoryRevision: UInt = 0
    @Published private var pendingCompletions: [UUID: Bool] = [:]
    @Published var errorMessage: String?

    private let repository: TodoRepository
    private let notificationSource = UUID().uuidString
    private let broadcastsChanges: Bool
    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var pendingPreferenceSaves = 0
    private var pendingReminderSaves = 0
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private static let positionErrorMessage = "포스트잇 위치를 저장하지 못했어요. 다시 이동해 주세요."
    private static let sizeErrorMessage = "포스트잇 크기를 저장하지 못했어요. 다시 조정해 주세요."
    private static let fontErrorMessage = "글자 크기를 저장하지 못했어요. 다시 조정해 주세요."
    private static let colorErrorMessage = "포스트잇 색상을 저장하지 못했어요. 다시 선택해 주세요."

    var onShowStickyNotes: (([UUID]) -> Void)?

    var tasks: [TodoItem] { snapshot.tasks }
    var upcomingTasks: [TodoItem] { snapshot.upcomingTasks }

    func task(id: UUID) -> TodoItem? {
        tasks.first { $0.id == id } ?? upcomingTasks.first { $0.id == id }
    }
    var categories: [TodoCategory] { snapshot.categories }
    var defaultCategoryID: UUID? { categories.first(where: \.isDefault)?.id }
    var stickyNotes: [StickyNoteState] { snapshot.stickyNotes }
    var incompleteTasks: [TodoItem] { tasks.filter { !$0.isCompleted } }
    var completedTasks: [TodoItem] { tasks.filter(\.isCompleted) }
    var visibleStickyCount: Int { stickyNotes.filter(\.isVisible).count }
    var defaultStickyFontSize: Double { snapshot.stickyNoteDefaultFontSize }

    func categoryName(for task: TodoItem) -> String? {
        categories.first { $0.id == task.categoryID }?.name
    }

    func effectiveStickyFontSize(for note: StickyNoteState) -> Double {
        note.fontSize ?? defaultStickyFontSize
    }

    func isStickyVisible(for id: UUID) -> Bool {
        stickyNotes.contains { $0.id == id && $0.isVisible }
    }

    func isCompleting(_ id: UUID) -> Bool { pendingCompletions[id] != nil }

    func completionValue(for task: TodoItem) -> Bool {
        pendingCompletions[task.id] ?? task.isCompleted
    }

    init(store: TodoStore? = nil, broadcastsChanges: Bool = true) {
        repository = TodoRepository(store: store)
        self.broadcastsChanges = broadcastsChanges
        let ownSource = notificationSource
        observer = DistributedNotificationCenter.default().addObserver(
            forName: TodoStore.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.object as? String != ownSource else { return }
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        refreshRequested = true
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task {
            repeat {
                refreshRequested = false
                do {
                    let currentSnapshot = try await repository.fetchSnapshot()
                    // A newer request may follow a write that this read did not yet see.
                    guard !refreshRequested else { continue }
                    if snapshot != currentSnapshot { snapshot = currentSnapshot }
                    // A historical task can change without changing today's snapshot.
                    completionHistoryRevision &+= 1
                } catch {
                    guard !refreshRequested else { continue }
                    present(error)
                }
                if isLoading { isLoading = false }
            } while refreshRequested
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    func completedTasks(in range: DateInterval, categoryID: UUID? = nil) async throws -> [TodoItem] {
        try await repository.fetchCompletedTasks(in: range, categoryID: categoryID)
    }

    func add(title: String, categoryID: UUID? = nil, showAsStickyNote: Bool = false, plannedDay: Int? = nil) async -> Bool {
        await save {
            try await self.repository.add(title: title, categoryID: categoryID, showAsStickyNote: showAsStickyNote, plannedDay: plannedDay)
        }
    }

    func update(id: UUID, title: String) async -> Bool {
        await save { try await self.repository.update(id: id, title: title) }
    }

    func update(id: UUID, title: String, categoryID: UUID?, plannedDay: Int?) async -> Bool {
        await save { try await self.repository.update(id: id, title: title, categoryID: categoryID, plannedDay: plannedDay) }
    }

    func setCategory(id: UUID, categoryID: UUID?) async -> Bool {
        await save { try await self.repository.setCategory(id: id, categoryID: categoryID) }
    }

    func createCategory(name: String) async -> Bool {
        await createCategoryReturningID(name: name) != nil
    }

    func createCategoryReturningID(name: String) async -> UUID? {
        var createdID: UUID?
        let succeeded = await save {
            createdID = try await self.repository.createCategory(name: name)
        }
        return succeeded ? createdID : nil
    }

    func reorderCategories(ids: [UUID]) async -> Bool {
        await save { try await self.repository.reorderCategories(ids: ids) }
    }

    func renameCategory(id: UUID, name: String) async -> Bool {
        await save { try await self.repository.renameCategory(id: id, name: name) }
    }

    func deleteCategory(id: UUID, movingTasksTo destinationID: UUID? = nil) async -> Bool {
        await save { try await self.repository.deleteCategory(id: id, movingTasksTo: destinationID) }
    }

    func reminder(for id: UUID) -> TodoReminder? {
        snapshot.reminders.first { $0.id == id }
    }

    func setReminder(id: UUID, localTime: ReminderLocalTime) async -> Bool {
        await save { try await self.repository.setReminder(id: id, localTime: localTime) }
    }

    func removeReminder(id: UUID) async -> Bool {
        await save { try await self.repository.removeReminder(id: id) }
    }

    func loadPendingReminders() async throws -> [TodoReminderCandidate] {
        try await repository.loadPendingReminders()
    }

    func markRemindersDelivered(generations: [UUID], at date: Date) async throws {
        pendingReminderSaves += 1
        defer {
            pendingReminderSaves -= 1
            resumeSaveWaitersIfIdle()
        }
        try await repository.markRemindersDelivered(generations: generations, at: date)
        notifyChange(reloadWidgets: false)
        await refresh()
    }

    @discardableResult
    func setCompleted(_ task: TodoItem, completed: Bool) async -> Bool {
        guard !isSaving, !isCompleting(task.id) else { return false }
        pendingCompletions[task.id] = completed
        if errorMessage != nil { errorMessage = nil }
        defer {
            pendingCompletions.removeValue(forKey: task.id)
            resumeSaveWaitersIfIdle()
        }
        do {
            try await repository.setCompleted(id: task.id, completed: completed)
            notifyChange(reloadWidgets: true)
            await refresh()
            return true
        } catch {
            present(error)
            await refresh()
            return false
        }
    }

    func delete(_ task: TodoItem) async -> Bool {
        await save { try await self.repository.delete(id: task.id) }
    }

    func showStickyNotes(_ ids: [UUID]) async -> Bool {
        await setStickyNoteVisibility(showing: ids, hiding: [])
    }

    func hideStickyNotes(_ ids: [UUID]) async -> Bool {
        await setStickyNoteVisibility(showing: [], hiding: ids)
    }

    func setStickyNoteVisibility(showing: [UUID], hiding: [UUID]) async -> Bool {
        guard !showing.isEmpty || !hiding.isEmpty else { return true }
        let succeeded = await save(reloadWidgets: false) {
            try await self.repository.setStickyNoteVisibility(showing: showing, hiding: hiding)
        }
        if succeeded && !showing.isEmpty { onShowStickyNotes?(showing) }
        return succeeded
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
        guard isSaving || !pendingCompletions.isEmpty || pendingPreferenceSaves > 0 || pendingReminderSaves > 0 else { return }
        await withCheckedContinuation { continuation in
            saveWaiters.append(continuation)
        }
    }

    func saveStickySize(id: UUID, size: StickyNoteSize) async {
        do {
            try await repository.saveStickySize(id: id, size: size)
            if errorMessage == Self.sizeErrorMessage { errorMessage = nil }
        } catch {
            errorMessage = Self.sizeErrorMessage
        }
    }

    func setStickyFontSize(id: UUID, fontSize: Double?) async {
        _ = await saveStickyAppearance(failureMessage: Self.fontErrorMessage) {
            try await self.repository.saveStickyFontSize(id: id, fontSize: fontSize)
        }
    }

    func setDefaultStickyFontSize(_ fontSize: Double) async {
        _ = await saveStickyAppearance(failureMessage: Self.fontErrorMessage) {
            try await self.repository.saveDefaultStickyFontSize(fontSize)
        }
    }

    func setCategoryStickyColor(id: UUID, colorHex: String?) async -> Bool {
        await save(reloadWidgets: false) {
            try await self.repository.saveCategoryStickyColor(id: id, colorHex: colorHex)
        }
    }

    func setStickyColor(id: UUID, colorHex: String?) async -> Bool {
        await saveStickyAppearance(failureMessage: Self.colorErrorMessage) {
            try await self.repository.saveStickyColor(id: id, colorHex: colorHex)
        }
    }

    private func saveStickyAppearance(failureMessage: String, _ operation: () async throws -> Void) async -> Bool {
        pendingPreferenceSaves += 1
        defer {
            pendingPreferenceSaves -= 1
            resumeSaveWaitersIfIdle()
        }
        do {
            try await operation()
            if errorMessage == failureMessage { errorMessage = nil }
            notifyChange(reloadWidgets: false)
            await refresh()
            return true
        } catch {
            errorMessage = failureMessage
            return false
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
            isSaving = false
            resumeSaveWaitersIfIdle()
        }
        do {
            try await operation()
            notifyChange(reloadWidgets: reloadWidgets)
            await refresh()
            return true
        } catch {
            present(error)
            await refresh()
            return false
        }
    }

    private func notifyChange(reloadWidgets: Bool) {
        guard broadcastsChanges else { return }
        DistributedNotificationCenter.default().postNotificationName(
            TodoStore.notificationName,
            object: notificationSource,
            userInfo: nil,
            deliverImmediately: true
        )
        if reloadWidgets { WidgetCenter.shared.reloadAllTimelines() }
    }

    private func resumeSaveWaitersIfIdle() {
        guard !isSaving, pendingCompletions.isEmpty, pendingPreferenceSaves == 0, pendingReminderSaves == 0 else { return }
        let waiters = saveWaiters
        saveWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func present(_ error: Error) {
        switch error as? TodoStoreError {
        case .invalidReminder?, .completedTaskReminder?, .emptyTitle?, .missingTask?, .invalidCategoryName?, .duplicateCategoryName?, .missingCategory?, .lastCategory?, .invalidCategoryDestination?, .invalidCategoryOrder?:
            errorMessage = error.localizedDescription
        case .unavailableAppGroup?:
            errorMessage = "할 일 저장 공간에 접근할 수 없어요."
        default:
            errorMessage = "할 일을 저장하거나 불러오지 못했어요. 잠시 후 다시 시도해 주세요."
        }
    }
}
