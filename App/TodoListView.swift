import SwiftUI

struct TodoListView: View {
    @ObservedObject var model: TodoListModel
    @ObservedObject var reminders: ReminderCoordinator
    @State private var listPosition = ScrollPosition(edge: .top)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingTask: TodoItem?
    @State private var deletingTask: TodoItem?
    @State private var showingStickyPicker = false
    @State private var isSavingFontSize = false
    @State private var collapsedCategories: Set<String> = []
    @State private var addingCategory: TodoCategory?
    @State private var showingCategories = false
    @State private var categoryMoveNotice: TodoCategory?
    @State private var showingCompletionHistory = false
    @State private var showingReminderSettings = false
    @State private var reminderTask: TodoItem?
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("오늘의 목록")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showingCompletionHistory = true } label: {
                    Label("이전 완료", systemImage: "calendar")
                }
                .buttonStyle(.borderless).controlSize(.small).disabled(model.isLoading)
                stickyManagementMenu
                Button { showingReminderSettings = true } label: {
                    Image(systemName: "bell")
                }
                .buttonStyle(.plain)
                .help("알림 설정").accessibilityLabel("알림 설정")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack {
                Spacer()
                Button("카테고리 관리", systemImage: "slider.horizontal.3") { showingCategories = true }
            }
            .buttonStyle(.borderless).controlSize(.small)
            .disabled(model.isLoading || model.isSaving)
            .padding(.horizontal, 16).padding(.bottom, 12)
            if let category = categoryMoveNotice {
                HStack(spacing: 8) {
                    Text("‘\(category.name)’ 카테고리로 이동했어요.")
                        .font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                    Button { categoryMoveNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("이동 안내 닫기")
                }
                .controlSize(.small)
                .padding(.horizontal, 16).padding(.bottom, 10)
            }

            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        statusSection(completed: false)
                        if !model.upcomingTasks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("예정된 할 일")
                                    .font(.title2.weight(.bold))
                                    .accessibilityAddTraits(.isHeader)
                                taskRows(model.upcomingTasks, upcoming: true)
                            }
                        }
                        statusSection(completed: true)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.completedTasks.map(\.id))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollPosition($listPosition)
                .defaultScrollAnchor(.top, for: .sizeChanges)
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .sheet(item: $editingTask) { task in
            EditTaskView(model: model, task: task, didMoveCategory: showCategoryMoveNotice)
        }
        .sheet(item: $addingCategory) { category in
            CategoryTaskEntry(model: model, categoryID: category.id) {
                collapsedCategories.remove("pending:\(category.id)")
            }
        }
        .sheet(isPresented: $showingStickyPicker) {
            StickyNotePickerView(model: model)
        }
        .sheet(isPresented: $showingCategories) {
            TodoCategoryManager(model: model)
        }
        .sheet(isPresented: $showingCompletionHistory) {
            CompletionHistoryView(model: model, initialCategoryID: nil)
        }
        .sheet(isPresented: $showingReminderSettings) {
            ReminderSettingsView(coordinator: reminders)
        }
        .sheet(item: $reminderTask) { task in
            TodoReminderEditor(model: model, coordinator: reminders, taskID: task.id)
        }
        .confirmationDialog("할 일을 삭제할까요?", isPresented: Binding(
            get: { deletingTask != nil },
            set: { if !$0 { deletingTask = nil } }
        ), titleVisibility: .visible, presenting: deletingTask) { task in
            Button("삭제", role: .destructive) {
                Task { _ = await model.delete(task) }
            }
            .disabled(model.isSaving)
            Button("취소", role: .cancel) { deletingTask = nil }
        } message: { task in
            Text(task.title)
        }
        .alert("처리하지 못했어요", isPresented: Binding(
            get: { model.errorMessage != nil && !showingCompletionHistory && addingCategory == nil && editingTask == nil && reminderTask == nil && !showingReminderSettings && !showingStickyPicker && !showingCategories && controlActiveState == .key },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("다시 불러오기") {
                model.errorMessage = nil
                Task { await model.refresh() }
            }
            Button("확인", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.categories) { _, categories in
            if let notice = categoryMoveNotice {
                categoryMoveNotice = categories.first { $0.id == notice.id }
            }
        }
    }

    private func statusSection(completed: Bool) -> some View {
        let tasks = model.tasks.filter { $0.isCompleted == completed }
        let grouped = Dictionary(grouping: tasks, by: \.categoryID)
        let categories = model.categories.filter { !completed || !(grouped[$0.id] ?? []).isEmpty }
        return VStack(alignment: .leading, spacing: 18) {
            Text(completed ? "한 일" : "할 일")
                .font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            ForEach(categories) { category in
                categorySection(category, tasks: grouped[category.id] ?? [], completed: completed)
            }
            if completed && tasks.isEmpty {
                Text("아직 완료한 일이 없어요")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .id(completed ? "completed-tasks" : "incomplete-tasks")
    }

    private func categorySection(_ category: TodoCategory, tasks: [TodoItem], completed: Bool) -> some View {
        let key = "\(completed ? "completed" : "pending"):\(category.id)"
        let isCollapsed = collapsedCategories.contains(key)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        if isCollapsed { collapsedCategories.remove(key) }
                        else { collapsedCategories.insert(key) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .frame(width: 16, height: 24)
                        Text(category.name).font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if isCollapsed {
                            Text("\(tasks.count)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(completed ? "한 일" : "할 일") · \(category.name) \(isCollapsed ? "펼치기" : "접기")")
                .accessibilityValue(isCollapsed ? "접힘" : "펼침")
                Spacer(minLength: 8)
                if !completed {
                    Button { addingCategory = category } label: {
                        Image(systemName: "plus").frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(category.name)에 할 일 추가")
                    .help("\(category.name)에 할 일 추가")
                    .disabled(model.isSaving || model.isLoading)
                }
            }
            Divider().padding(.bottom, 4)
            if !isCollapsed {
                if tasks.isEmpty {
                    Text("할 일이 없어요")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    taskRows(tasks)
                }
            }
        }
    }

    private var stickyManagementMenu: some View {
        Menu {
            Button("할 일 선택해서 띄우기…", systemImage: "note") {
                showingStickyPicker = true
            }
            .disabled(model.incompleteTasks.isEmpty || model.isSaving)

            Button("모두 숨기기", systemImage: "eye.slash") {
                Task { _ = await model.hideAllStickyNotes() }
            }
            .disabled(model.visibleStickyCount == 0 || model.isSaving)
            .help("할 일의 완료 상태를 바꾸지 않고 모든 포스트잇을 숨깁니다.")

            Divider()
            Menu("기본 글자 크기") {
                Text("현재 \(model.defaultStickyFontSize.formatted()) pt")
                Divider()
                Button("작게") {
                    changeDefaultStickyFontSize(max(
                        StickyNoteTypography.minimumFontSize,
                        model.defaultStickyFontSize - StickyNoteTypography.fontSizeStep
                    ))
                }
                .disabled(model.defaultStickyFontSize <= StickyNoteTypography.minimumFontSize)

                Button("크게") {
                    changeDefaultStickyFontSize(min(
                        StickyNoteTypography.maximumFontSize,
                        model.defaultStickyFontSize + StickyNoteTypography.fontSizeStep
                    ))
                }
                .disabled(model.defaultStickyFontSize >= StickyNoteTypography.maximumFontSize)

                Divider()
                Button("기본값 (\(StickyNoteTypography.defaultFontSize.formatted()) pt)") {
                    changeDefaultStickyFontSize(StickyNoteTypography.defaultFontSize)
                }
                .disabled(model.defaultStickyFontSize == StickyNoteTypography.defaultFontSize)
            }
            .disabled(isSavingFontSize)
        } label: {
            Label("포스트잇 관리", systemImage: "note")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
    }

    private func changeDefaultStickyFontSize(_ fontSize: Double) {
        guard !isSavingFontSize else { return }
        isSavingFontSize = true
        Task {
            defer { isSavingFontSize = false }
            await model.setDefaultStickyFontSize(fontSize)
        }
    }

    private func taskRows(_ tasks: [TodoItem], upcoming: Bool = false) -> some View {
        ForEach(tasks) { task in
            TodoTaskRow(
                model: model,
                taskID: task.id,
                upcoming: upcoming,
                edit: { editingTask = $0 },
                delete: { deletingTask = $0 },
                editReminder: { reminderTask = $0 },
                didMoveCategory: showCategoryMoveNotice
            )
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    private func showCategoryMoveNotice(_ category: TodoCategory) {
        categoryMoveNotice = category
    }


}

// Resolve current data by identity so moving between sections cannot retain a stale task.
// The row also observes pending-save changes when ForEach's task values are unchanged.
private struct TodoTaskRow: View {
    @ObservedObject var model: TodoListModel
    let taskID: UUID
    let upcoming: Bool
    let edit: (TodoItem) -> Void
    let delete: (TodoItem) -> Void
    let editReminder: (TodoItem) -> Void
    let didMoveCategory: (TodoCategory) -> Void

    var body: some View {
        if let task = model.task(id: taskID) {
            taskContent(task)
        }
    }

    private func taskContent(_ task: TodoItem) -> some View {
        let isCompleted = model.completionValue(for: task)
        let isBusy = model.isSaving || model.isCompleting(task.id)
        return HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: Binding(
                get: { isCompleted },
                set: { value in Task { await model.setCompleted(task, completed: value) } }
            )) { Text(task.title) }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(task.title)
            .disabled(isBusy)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                .foregroundStyle(isCompleted ? .secondary : .primary)
                .strikethrough(isCompleted, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                if upcoming, let day = task.plannedDay, let date = TodoPlannedDay.date(for: day) {
                    HStack(spacing: 6) {
                        Text(date, format: .dateTime.month().day().year())
                        if let category = model.categoryName(for: task) { Text(category) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let reminder = model.reminder(for: task.id), let date = reminder.schedule.date() {
                    Label {
                        Text(date, format: .dateTime.month().day().hour().minute())
                        if reminder.deliveredAt != nil { Text("알림 전달됨") }
                    } icon: { Image(systemName: reminder.deliveredAt == nil ? "bell" : "bell.badge") }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            Menu {
                taskActions(task)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isBusy)
            .accessibilityLabel("\(task.title) 옵션")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu { taskActions(task) }
    }

    @ViewBuilder
    private func categoryActions(_ task: TodoItem) -> some View {
        ForEach(model.categories) { category in
            Button {
                Task {
                    if await model.setCategory(id: task.id, categoryID: category.id) { didMoveCategory(category) }
                }
            } label: {
                if category.id == task.categoryID { Label(category.name, systemImage: "checkmark") }
                else { Text(category.name) }
            }
            .disabled(category.id == task.categoryID || model.isSaving || model.isCompleting(task.id))
        }
    }

    @ViewBuilder
    private func taskActions(_ task: TodoItem) -> some View {
        let isBusy = model.isSaving || model.isCompleting(task.id)
        if !model.completionValue(for: task) {
            Button("알림…", systemImage: "bell") { editReminder(task) }.disabled(isBusy)
            Divider()
        }
        if !upcoming && !model.completionValue(for: task) {
            Button(model.isStickyVisible(for: task.id) ? "포스트잇 앞으로 가져오기" : "포스트잇 띄우기", systemImage: "note") {
                Task { _ = await model.showStickyNotes([task.id]) }
            }
            .disabled(isBusy)
            if model.isStickyVisible(for: task.id) {
                Button("포스트잇 숨기기", systemImage: "eye.slash") {
                    Task { _ = await model.hideStickyNotes([task.id]) }
                }
                .disabled(isBusy)
            }
            Divider()
        }
        Menu("카테고리 이동", systemImage: "folder") { categoryActions(task) }
            .disabled(isBusy)
        Button("수정", systemImage: "pencil") { edit(task) }
            .disabled(isBusy)
        Button("삭제", systemImage: "trash", role: .destructive) { delete(task) }
            .disabled(isBusy)
    }
}

private struct StickyNotePickerView: View {
    @ObservedObject var model: TodoListModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID> = []

    private var availableIDs: [UUID] { model.incompleteTasks.map(\.id) }
    private var selectedCount: Int { selectedIDs.intersection(availableIDs).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("포스트잇 띄우기").font(.headline)
            Text("바탕화면에 띄울 할 일을 선택하세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("전체 선택") { selectedIDs = Set(availableIDs) }
                    .disabled(availableIDs.isEmpty || selectedCount == availableIDs.count || model.isSaving)
                Button("선택 해제") { selectedIDs.removeAll() }
                    .disabled(selectedCount == 0 || model.isSaving)
                Spacer()
                Text("\(selectedCount)개 선택")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)

            if model.incompleteTasks.isEmpty {
                Text("띄울 수 있는 미완료 할 일이 없어요.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                List(model.incompleteTasks) { task in
                    Toggle(isOn: Binding(
                        get: { selectedIDs.contains(task.id) },
                        set: { isSelected in
                            if isSelected { selectedIDs.insert(task.id) }
                            else { selectedIDs.remove(task.id) }
                        }
                    )) {
                        HStack {
                            Text(task.title)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if model.isStickyVisible(for: task.id) {
                                Text("표시 중")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(model.isSaving)
                    .padding(.vertical, 4)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
                .frame(minHeight: 140, idealHeight: 240, maxHeight: 320)
            }

            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("취소") {
                    model.errorMessage = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSaving)
                Button("띄우기") {
                    let ids = availableIDs.filter { selectedIDs.contains($0) }
                    Task {
                        if await model.showStickyNotes(ids) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCount == 0 || model.isSaving)
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(model.isSaving)
        .onAppear { model.errorMessage = nil }
        .onChange(of: availableIDs) { _, ids in
            selectedIDs.formIntersection(ids)
        }
    }
}

private struct EditTaskView: View {
    @ObservedObject var model: TodoListModel
    let task: TodoItem
    let didMoveCategory: (TodoCategory) -> Void
    @State private var title: String
    @State private var categoryID: UUID?
    @State private var plannedDate: Date?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    init(model: TodoListModel, task: TodoItem, didMoveCategory: @escaping (TodoCategory) -> Void) {
        self.model = model
        self.task = task
        self.didMoveCategory = didMoveCategory
        _title = State(initialValue: task.title)
        _categoryID = State(initialValue: task.categoryID)
        _plannedDate = State(initialValue: task.plannedDay.flatMap(TodoPlannedDay.date(for:)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("할 일 수정").font(.headline)
            TodoCategoryPicker(model: model, selection: $categoryID)
            TextField("할 일", text: $title, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .disabled(model.isSaving)
            if !task.isCompleted { PlannedDatePicker(date: $plannedDate) }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("취소") {
                    model.errorMessage = nil
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                Button("저장") {
                    Task {
                        if await model.update(id: task.id, title: title, categoryID: categoryID, plannedDay: plannedDate.map(TodoPlannedDay.key(for:))) {
                            if let updated = model.task(id: task.id),
                               updated.categoryID != task.categoryID,
                               let category = model.categories.first(where: { $0.id == updated.categoryID }) {
                                didMoveCategory(category)
                            }
                            model.errorMessage = nil
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving || model.isLoading || model.defaultCategoryID == nil)
            }
        }
        .padding(24)
        .frame(width: 380)
        .disabled(model.isSaving)
        .interactiveDismissDisabled(model.isSaving)
        .onAppear { model.errorMessage = nil; isFocused = true }
    }
}

private struct CategoryTaskEntry: View {
    @ObservedObject var model: TodoListModel
    let categoryID: UUID
    let onAdded: () -> Void
    @State private var title = ""
    @State private var plannedDate: Date?
    @State private var showAsStickyNote = false
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss
    private var category: TodoCategory? { model.categories.first { $0.id == categoryID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(category.map { "\($0.name)에 할 일 추가" } ?? "카테고리를 찾을 수 없어요")
                .font(.headline)
            TextField("할 일", text: $title)
                .textFieldStyle(.roundedBorder).focused($isFocused).onSubmit(save)
            PlannedDatePicker(date: $plannedDate)
            if !isFuturePlan {
                Toggle("추가 후 포스트잇 표시", isOn: $showAsStickyNote).toggleStyle(.checkbox)
            }
            if category == nil {
                Text("입력 내용을 복사한 뒤 다른 카테고리에서 추가해 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("취소") { model.errorMessage = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("추가", action: save).keyboardShortcut(.defaultAction)
                    .disabled(category == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 360)
        .disabled(model.isSaving || model.isLoading)
        .interactiveDismissDisabled()
        .onAppear { model.errorMessage = nil; isFocused = true }
    }

    private var isFuturePlan: Bool {
        plannedDate.map(TodoPlannedDay.key(for:)).map { $0 > TodoPlannedDay.key(for: Date()) } ?? false
    }

    private func save() {
        guard category != nil, !model.isSaving, !model.isLoading,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submittedTitle = title
        let sticky = showAsStickyNote && !isFuturePlan
        let day = plannedDate.map(TodoPlannedDay.key(for:))
        Task {
            if await model.add(title: submittedTitle, categoryID: categoryID, showAsStickyNote: sticky, plannedDay: day) {
                onAdded()
                dismiss()
            }
        }
    }
}

struct QuickAddView: View {
    @ObservedObject var model: TodoListModel
    let onSave: () -> Void
    @State private var title = ""
    @State private var plannedDate: Date?
    @State private var showAsStickyNote = false
    @State private var categoryID: UUID?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("할 일 추가", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
                .disabled(model.isSaving)
            TodoCategoryPicker(model: model, selection: $categoryID)
            PlannedDatePicker(date: $plannedDate).disabled(model.isSaving)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if !isFuturePlan {
                    Toggle("추가 후 포스트잇 표시", isOn: $showAsStickyNote)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .disabled(model.isSaving)
                }
                Spacer()
                Button("추가", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving || model.isLoading || model.defaultCategoryID == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { isFocused = true }
    }

    private var isFuturePlan: Bool {
        plannedDate.map(TodoPlannedDay.key(for:)).map { $0 > TodoPlannedDay.key(for: Date()) } ?? false
    }

    private func save() {
        guard !model.isSaving, !model.isLoading, model.defaultCategoryID != nil,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submittedTitle = title
        let submittedStickyChoice = showAsStickyNote && !isFuturePlan
        let day = plannedDate.map(TodoPlannedDay.key(for:))
        let submittedCategoryID = categoryID ?? model.defaultCategoryID
        Task {
            if await model.add(title: submittedTitle, categoryID: submittedCategoryID, showAsStickyNote: submittedStickyChoice, plannedDay: day) {
                title = ""
                plannedDate = nil
                showAsStickyNote = false
                categoryID = model.defaultCategoryID
                onSave()
            }
        }
    }
}


private struct PlannedDatePicker: View {
    @Binding var date: Date?

    var body: some View {
        HStack {
            Toggle("날짜 지정", isOn: Binding(
                get: { date != nil },
                set: { enabled in
                    date = enabled ? Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Date()) : nil
                }
            ))
            .toggleStyle(.checkbox)
            if let selected = date {
                DatePicker("예정 날짜", selection: Binding(
                    get: { date ?? selected },
                    set: { date = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .accessibilityLabel("예정 날짜")
            }
        }
    }
}

private struct TodoCategoryPicker: View {
    @ObservedObject var model: TodoListModel
    @Binding var selection: UUID?
    @State private var showingNewCategory = false

    private var selectedCategory: TodoCategory? {
        model.categories.first { $0.id == selection } ?? model.categories.first { $0.isDefault }
    }

    var body: some View {
        HStack {
            Text("카테고리").font(.callout).foregroundStyle(.secondary)
            Menu {
                ForEach(model.categories) { category in
                    Button { selection = category.id } label: {
                        if selectedCategory?.id == category.id { Label(category.name, systemImage: "checkmark") }
                        else { Text(category.name) }
                    }
                }
                Divider()
                Button("새 카테고리…", systemImage: "plus") { showingNewCategory = true }
            } label: {
                Text(selectedCategory?.name ?? "불러오는 중…").lineLimit(1)
            }
            .menuStyle(.borderedButton).fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("카테고리 선택")
        }
        .controlSize(.small)
        .disabled(model.isSaving || model.isLoading)
        .onAppear(perform: selectValidCategory)
        .onChange(of: model.categories) { _, _ in selectValidCategory() }
        .sheet(isPresented: $showingNewCategory) {
            TodoCategoryNameEditor(model: model) { selection = $0 }
        }
    }

    private func selectValidCategory() {
        if !model.categories.contains(where: { $0.id == selection }) { selection = model.defaultCategoryID }
    }
}

private enum CategoryManagementSheet: Identifiable {
    case create, rename(TodoCategory), delete(TodoCategory)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let category): "rename-\(category.id)"
        case .delete(let category): "delete-\(category.id)"
        }
    }
}

private struct TodoCategoryManager: View {
    @ObservedObject var model: TodoListModel
    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: CategoryManagementSheet?
    @State private var displayedCategories: [TodoCategory] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("카테고리 관리").font(.headline)
                Spacer()
                Button("새 카테고리", systemImage: "plus") { activeSheet = .create }
                    .controlSize(.small)
            }
            List {
                    ForEach(displayedCategories) { category in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 32)
                                .contentShape(Rectangle())
                                .help("드래그하여 순서 변경")
                                .accessibilityLabel("\(category.name) 순서 변경")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(category.name).lineLimit(2)
                                Text(category.isDefault ? "\(category.taskCount)개 · 기본 추가 카테고리" : "\(category.taskCount)개")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button { activeSheet = .rename(category) } label: { Image(systemName: "pencil") }
                                .help("이름 변경").accessibilityLabel("\(category.name) 이름 변경")
                            Button { activeSheet = .delete(category) } label: { Image(systemName: "trash") }
                                .disabled(model.categories.count <= 1)
                                .help(model.categories.count <= 1 ? "마지막 카테고리는 삭제할 수 없어요." : "다른 카테고리로 이동 후 삭제")
                                .accessibilityLabel("\(category.name) 삭제")
                        }
                        .controlSize(.small).padding(.vertical, 10)
                    }
                    .onMove { offsets, destination in
                        // Update the list immediately so the native drop animation never snaps back.
                        displayedCategories.move(fromOffsets: offsets, toOffset: destination)
                        let ids = displayedCategories.map(\.id)
                        Task {
                            _ = await model.reorderCategories(ids: ids)
                            displayedCategories = model.categories
                        }
                    }
            }
            .listStyle(.inset)
            .frame(height: 260)
            if activeSheet == nil, let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 440)
        .disabled(model.isSaving || model.isLoading)
        .onAppear { displayedCategories = model.categories }
        .onChange(of: model.categories) { _, categories in
            displayedCategories = categories
        }
        .interactiveDismissDisabled(model.isSaving)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .create: TodoCategoryNameEditor(model: model)
            case .rename(let category): TodoCategoryNameEditor(model: model, category: category)
            case .delete(let category): TodoCategoryDeleteView(model: model, category: category)
            }
        }
    }
}

private struct TodoCategoryNameEditor: View {
    @ObservedObject var model: TodoListModel
    let category: TodoCategory?
    let onCreated: (UUID) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    init(model: TodoListModel, category: TodoCategory? = nil, onCreated: @escaping (UUID) -> Void = { _ in }) {
        self.model = model
        self.category = category
        self.onCreated = onCreated
        _name = State(initialValue: category?.name ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedName.isEmpty && trimmedName.count <= TodoCategory.maximumNameLength
            && trimmedName != category?.name && !model.isSaving && !model.isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(category == nil ? "새 카테고리" : "카테고리 이름 변경").font(.headline)
            TextField("카테고리 이름", text: $name)
                .textFieldStyle(.roundedBorder).focused($isFocused).onSubmit(save)
            Text("최대 \(TodoCategory.maximumNameLength)자")
                .font(.caption).foregroundStyle(trimmedName.count > TodoCategory.maximumNameLength ? .red : .secondary)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("취소") { model.errorMessage = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button(category == nil ? "추가" : "저장", action: save)
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(24).frame(width: 360)
        .disabled(model.isSaving)
        .interactiveDismissDisabled()
        .onAppear { model.errorMessage = nil; isFocused = true }
    }

    private func save() {
        guard canSave else { return }
        let submittedName = trimmedName
        Task {
            if let category {
                if await model.renameCategory(id: category.id, name: submittedName) { dismiss() }
            } else if let id = await model.createCategoryReturningID(name: submittedName) {
                onCreated(id)
                dismiss()
            }
        }
    }
}

private struct TodoCategoryDeleteView: View {
    @ObservedObject var model: TodoListModel
    let category: TodoCategory
    @State private var destinationID: UUID?
    @Environment(\.dismiss) private var dismiss

    private var destinations: [TodoCategory] { model.categories.filter { $0.id != category.id } }
    private var currentCategory: TodoCategory? { model.categories.first { $0.id == category.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("카테고리 삭제").font(.headline)
            if let current = currentCategory {
                Text("‘\(current.name)’의 할 일 \(current.taskCount)개를 다른 카테고리로 옮긴 후 삭제해요.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("이전에 완료한 할 일도 함께 이동하며, 완료 기록·포스트잇·알림은 유지돼요.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("이동할 카테고리", selection: $destinationID) {
                    ForEach(destinations) { destination in
                        Text(destination.name).tag(Optional(destination.id))
                    }
                }
                if current.isDefault {
                    Text("선택한 카테고리가 기본 추가 카테고리가 됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if destinations.isEmpty {
                    Text("마지막 카테고리는 삭제할 수 없어요.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("이미 삭제된 카테고리예요.")
            }
            if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("취소") { model.errorMessage = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("이동 후 삭제", role: .destructive, action: remove)
                    .disabled(currentCategory == nil || destinationID == nil || destinations.isEmpty)
            }
        }
        .padding(24).frame(width: 400)
        .disabled(model.isSaving || model.isLoading)
        .interactiveDismissDisabled()
        .onAppear { model.errorMessage = nil; selectValidDestination() }
        .onChange(of: model.categories) { _, _ in selectValidDestination() }
    }

    private func selectValidDestination() {
        if !destinations.contains(where: { $0.id == destinationID }) {
            destinationID = destinations.first(where: \.isDefault)?.id ?? destinations.first?.id
        }
    }

    private func remove() {
        guard !model.isSaving, let destinationID, destinations.contains(where: { $0.id == destinationID }) else { return }
        Task {
            if await model.deleteCategory(id: category.id, movingTasksTo: destinationID) { dismiss() }
        }
    }
}
