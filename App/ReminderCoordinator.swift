import AppKit
import Combine
import CryptoKit
import ServiceManagement
import UserNotifications

/// Schedules one timer for the next reminder, reconciling all overdue work together after wake/login.
/// A normal window close leaves this service running. Explicit application termination stops it.
@MainActor
final class ReminderCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    typealias LoadReminders = @MainActor () async throws -> [TodoReminderCandidate]
    typealias MarkDelivered = @MainActor ([UUID], Date) async throws -> Void

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var isRequestingAccess = false
    @Published var errorMessage: String?

    var canSchedule: Bool { authorizationStatus == .authorized || authorizationStatus == .provisional }
    var startsAtLogin: Bool { loginStatus == .enabled }
    var onOpenList: (() -> Void)?

    private let center: UNUserNotificationCenter
    private let loadReminders: LoadReminders
    private let markDelivered: MarkDelivered
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private var timer: Timer?
    private var reconciliation: Task<Void, Never>?
    private var reconciliationRequested = false
    private var started = false
    private var sleeping = false
    private var deliveredGenerations = Set<UUID>()
    private static let generationKey = "reminderGenerations"

    init(
        center: UNUserNotificationCenter = .current(),
        loadReminders: @escaping LoadReminders,
        markDelivered: @escaping MarkDelivered,
        now: @escaping () -> Date = Date.init,
        timeZone: @escaping () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.center = center
        self.loadReminders = loadReminders
        self.markDelivered = markDelivered
        self.now = now
        self.timeZone = timeZone
    }

    func start() {
        guard !started else { return }
        started = true
        center.delegate = self
        let defaults = NotificationCenter.default
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange,
                     NSApplication.didBecomeActiveNotification] {
            defaults.addObserver(self, selector: #selector(environmentChanged), name: name, object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(environmentChanged),
            name: TodoStore.notificationName, object: nil
        )
        requestReconciliation()
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        reconciliation?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Call only in response to the user's notification-enable action.
    func requestAuthorization() async {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            errorMessage = nil
        } catch {
            errorMessage = "알림 권한을 요청하지 못했어요. 다시 시도해 주세요."
        }
        await refreshAccess()
        requestReconciliation()
    }

    func setStartsAtLogin(_ enabled: Bool) async {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try await SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "로그인 시 실행 설정을 바꾸지 못했어요. 시스템 설정을 확인해 주세요."
        }
        loginStatus = SMAppService.mainApp.status
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func refreshAccess() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
        loginStatus = SMAppService.mainApp.status
    }

    func requestReconciliation() {
        guard started, !sleeping else { return }
        reconciliationRequested = true
        guard reconciliation == nil else { return }
        reconciliation = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.reconciliationRequested = false
                await self.reconcileOnce()
            } while self.reconciliationRequested && self.started && !self.sleeping && !Task.isCancelled
            self.reconciliation = nil
        }
    }

    /// Wait before application exit so successful deliveries can persist their markers.
    func waitForDelivery() async { await reconciliation?.value }

    func finishAndStop() async {
        // Stop accepting new work without cancelling a delivery whose marker is still being saved.
        started = false
        reconciliationRequested = false
        timer?.invalidate()
        timer = nil
        await waitForDelivery()
        stop()
    }

    private func reconcileOnce() async {
        timer?.invalidate()
        timer = nil
        await refreshAccess()
        guard started, !sleeping, canSchedule, !Task.isCancelled else { return }
        do {
            // A delivered system notification can repair a marker write that failed before termination.
            let delivered = await center.deliveredNotifications()
            for notification in delivered {
                let values = notification.request.content.userInfo[Self.generationKey] as? [String] ?? []
                deliveredGenerations.formUnion(values.compactMap(UUID.init(uuidString:)))
            }
            var candidates = try await loadReminders()
            // Only undelivered database generations need crash-repair/deduplication memory.
            deliveredGenerations.formIntersection(Set(candidates.map { $0.reminder.generationID }))
            let repaired = candidates.filter { deliveredGenerations.contains($0.reminder.generationID) }
            if !repaired.isEmpty {
                let generations = Set(repaired.map { $0.reminder.generationID })
                try await markDelivered(Array(generations), now())
                candidates.removeAll { generations.contains($0.reminder.generationID) }
                deliveredGenerations.subtract(generations)
            }
            guard started, !sleeping, !Task.isCancelled else { return }
            let plan = ReminderDeliveryPlan.make(
                candidates: candidates, now: now(), timeZone: timeZone(), alreadyDelivered: deliveredGenerations
            )
            if !plan.due.isEmpty {
                // Refresh immediately before delivery to exclude newly completed/deleted/rescheduled tasks.
                let fresh = try await loadReminders()
                let currentPlan = ReminderDeliveryPlan.make(
                    candidates: fresh, now: now(), timeZone: timeZone(), alreadyDelivered: deliveredGenerations
                )
                guard started, !sleeping, !Task.isCancelled else { return }
                if !currentPlan.due.isEmpty {
                    let generations = currentPlan.due.map { $0.reminder.generationID }
                    let content = UNMutableNotificationContent()
                    content.title = currentPlan.due.count == 1 ? "할 일 알림" : "놓친 할 일 \(currentPlan.due.count)개"
                    let titles = currentPlan.due.prefix(3).map(\.title).joined(separator: "\n")
                    content.body = titles + (currentPlan.due.count > 3 ? "\n외 \(currentPlan.due.count - 3)개" : "")
                    content.sound = .default
                    content.userInfo = [Self.generationKey: generations.map(\.uuidString)]
                    let digest = SHA256.hash(data: Data(generations.map(\.uuidString).sorted().joined(separator: ",").utf8))
                    let identifier = "todo-reminder." + digest.map { String(format: "%02x", $0) }.joined()
                    try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                    deliveredGenerations.formUnion(generations)
                    try await markDelivered(generations, now())
                    deliveredGenerations.subtract(generations)
                }
                scheduleTimer(at: currentPlan.nextDate)
            } else {
                scheduleTimer(at: plan.nextDate)
            }
            errorMessage = nil
        } catch {
            errorMessage = "알림을 처리하지 못했어요. 잠시 후 다시 시도합니다."
            // Retry only a failed operation. Normal operation has no polling timer.
            scheduleTimer(at: now().addingTimeInterval(30))
        }
    }

    private func scheduleTimer(at date: Date?) {
        guard started, !sleeping, let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.requestReconciliation() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private nonisolated func environmentChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.requestReconciliation() }
    }

    @objc private nonisolated func willSleep(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.sleeping = true
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    @objc private nonisolated func didWake(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.sleeping = false
            self?.requestReconciliation()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await openFromNotification()
    }

    private func openFromNotification() { onOpenList?() }
}
