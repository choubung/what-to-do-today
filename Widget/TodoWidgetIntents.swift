import AppIntents
import Foundation
import WidgetKit

struct SetTodoCompletionIntent: AppIntent {
    static let title: LocalizedStringResource = "할 일 완료 상태 변경"
    static let isDiscoverable = false

    @Parameter(title: "할 일")
    var taskID: String

    @Parameter(title: "완료")
    var completed: Bool

    @Parameter(title: "위젯 크기")
    var familyKey: String

    init() {}

    init(taskID: UUID, completed: Bool, familyKey: String) {
        self.taskID = taskID.uuidString
        self.completed = completed
        self.familyKey = familyKey
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else {
            TodoWidgetState.setActionFailed(true, for: familyKey)
            return .result()
        }

        do {
            let store = try TodoStore.live()
            try store.setCompleted(id: id, completed: completed)
            DistributedNotificationCenter.default().postNotificationName(
                TodoStore.notificationName, object: nil, userInfo: nil, deliverImmediately: true
            )
            TodoWidgetState.setActionFailed(false, for: familyKey)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            TodoWidgetState.setActionFailed(true, for: familyKey)
        }
        return .result()
    }
}

struct ShowTodoPageIntent: AppIntent {
    static let title: LocalizedStringResource = "할 일 페이지 이동"
    static let isDiscoverable = false

    @Parameter(title: "페이지")
    var page: Int

    @Parameter(title: "위젯 크기")
    var familyKey: String

    init() {}

    init(page: Int, familyKey: String) {
        self.page = page
        self.familyKey = familyKey
    }

    func perform() async throws -> some IntentResult {
        TodoWidgetState.setPage(page, for: familyKey)
        TodoWidgetState.setActionFailed(false, for: familyKey)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct ReloadTodoWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "할 일 목록 다시 불러오기"
    static let isDiscoverable = false

    @Parameter(title: "위젯 크기")
    var familyKey: String

    init() {}

    init(familyKey: String) {
        self.familyKey = familyKey
    }

    func perform() async throws -> some IntentResult {
        TodoWidgetState.setActionFailed(false, for: familyKey)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
