import Foundation
import WidgetKit

enum TodoWidgetState {
    static let groupIdentifier = "group.com.choubung.whattodotoday"
    private static let pageLock = NSLock()

    static func familyKey(for family: WidgetFamily) -> String {
        family == .systemLarge ? "large" : "medium"
    }

    static func pageSize(for family: WidgetFamily) -> Int {
        family == .systemLarge ? 8 : 3
    }

    static func page(for familyKey: String) -> Int {
        defaults?.integer(forKey: "widget.page.\(familyKey)") ?? 0
    }

    static func setPage(_ page: Int, for familyKey: String) {
        pageLock.lock()
        defer { pageLock.unlock() }
        defaults?.set(max(0, page), forKey: "widget.page.\(familyKey)")
    }

    static func clampPage(_ page: Int, ifStill requestedPage: Int, for familyKey: String) {
        guard page != requestedPage else { return }
        pageLock.lock()
        defer { pageLock.unlock() }
        let key = "widget.page.\(familyKey)"
        guard let defaults, defaults.integer(forKey: key) == requestedPage else { return }
        defaults.set(page, forKey: key)
    }

    static func actionFailed(for familyKey: String) -> Bool {
        defaults?.bool(forKey: "widget.actionFailed.\(familyKey)") ?? false
    }

    static func setActionFailed(_ failed: Bool, for familyKey: String) {
        defaults?.set(failed, forKey: "widget.actionFailed.\(familyKey)")
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: groupIdentifier)
    }
}
