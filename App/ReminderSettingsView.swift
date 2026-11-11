import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

struct ReminderSettingsView: View {
    @ObservedObject var coordinator: ReminderCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("알림 설정").font(.headline)
            ReminderAccessPanel(coordinator: coordinator)
            Divider()
            Toggle("로그인 시 자동 실행", isOn: Binding(
                get: { coordinator.startsAtLogin },
                set: { enabled in Task { await coordinator.setStartsAtLogin(enabled) } }
            ))
            Text("로그인 시 자동 실행을 켜면 앱을 직접 열기 전에도 놓친 알림을 묶어 전달합니다. 창을 닫아도 알림은 계속되며, ⌘Q로 앱을 완전히 종료하면 다음 실행까지 알림이 멈춥니다.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = coordinator.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack { Spacer(); Button("완료") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 420)
        .task { await coordinator.refreshAccess() }
    }
}

struct TodoReminderEditor: View {
    @ObservedObject var model: TodoListModel
    @ObservedObject var coordinator: ReminderCoordinator
    let taskID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDate = Date().addingTimeInterval(300)
    @State private var isSaving = false

    private var existing: TodoReminder? { model.reminder(for: taskID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("할 일 알림").font(.headline)
            if let task = model.task(id: taskID) {
                Text(task.title).lineLimit(3)
            }
            ReminderAccessPanel(coordinator: coordinator)
            DatePicker("알림 시간", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
                .disabled(!coordinator.canSchedule || isSaving)
            Text("Mac의 현지 시각을 따릅니다. 시간대가 바뀌어도 지정한 날짜와 시각을 유지합니다.")
                .font(.caption).foregroundStyle(.secondary)
            if existing?.deliveredAt != nil {
                Text("이미 전달한 알림입니다. 다시 알리려면 새로운 시간을 저장하세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage ?? coordinator.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if existing != nil {
                    Button("알림 해제", role: .destructive) {
                        isSaving = true
                        Task {
                            defer { isSaving = false }
                            if await model.removeReminder(id: taskID) {
                                coordinator.requestReconciliation()
                                dismiss()
                            }
                        }
                    }
                }
                Spacer()
                Button("취소") { model.errorMessage = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장") {
                    let localTime = ReminderLocalTime(date: selectedDate)
                    guard let date = localTime.date(), date > Date() else {
                        model.errorMessage = "앞으로의 알림 시간을 선택해 주세요."
                        return
                    }
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        if await model.setReminder(id: taskID, localTime: localTime) {
                            coordinator.requestReconciliation()
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.canSchedule || (ReminderLocalTime(date: selectedDate).date() ?? .distantPast) <= Date())
            }
            .disabled(model.isSaving || isSaving)
        }
        .padding(24).frame(width: 440)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            model.errorMessage = nil
            if let date = existing?.schedule.date() { selectedDate = date }
        }
        .task { await coordinator.refreshAccess() }
    }
}

private struct ReminderAccessPanel: View {
    @ObservedObject var coordinator: ReminderCoordinator

    var body: some View {
        switch coordinator.authorizationStatus {
        case .notDetermined:
            Text("알림을 허용하면 지정한 시간에 할 일을 알려드리고, 로그인 시 자동으로 실행합니다.")
                .font(.callout).foregroundStyle(.secondary)
            Button("알림 허용") {
                Task {
                    await coordinator.requestAuthorization()
                    if coordinator.canSchedule { await coordinator.setStartsAtLogin(true) }
                }
            }
            .disabled(coordinator.isRequestingAccess)
        case .denied:
            Label("알림 권한이 꺼져 있어 시간을 설정할 수 없어요.", systemImage: "bell.slash")
                .font(.callout).foregroundStyle(.secondary)
            Text("시스템 설정 → 알림 → What to Do Today에서 알림을 허용해 주세요.")
                .font(.caption).foregroundStyle(.secondary)
            Button("시스템 설정 열기") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            }
        case .authorized, .provisional:
            Label("알림 사용 가능", systemImage: "bell.badge").font(.callout).foregroundStyle(.secondary)
            if coordinator.loginStatus == .requiresApproval {
                Text("로그인 후 자동으로 알리려면 시스템 설정에서 로그인 항목을 허용해 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("로그인 항목 설정 열기") { coordinator.openLoginSettings() }
            } else if !coordinator.startsAtLogin {
                Text("자동 실행이 꺼져 있어 로그인 후 앱을 직접 열어야 알림이 시작됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("로그인 시 자동 실행 켜기") {
                    Task { await coordinator.setStartsAtLogin(true) }
                }
            }
        default:
            Text("현재 알림을 사용할 수 없어요.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
