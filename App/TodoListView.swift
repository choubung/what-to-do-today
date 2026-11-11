import SwiftUI

struct TodoListView: View {
    @ObservedObject var model: TodoListModel
    @State private var newTitle = ""
    @State private var showNewTaskAsStickyNote = false
    @State private var editingTask: TodoItem?
    @State private var deletingTask: TodoItem?
    @State private var showingStickyPicker = false
    @State private var isSavingFontSize = false
    @FocusState private var isEntryFocused: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("할 일 추가", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isEntryFocused)
                    .onSubmit(addTask)
                    .disabled(model.isSaving)
                Button(action: addTask) {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                .help("할 일 추가")
                .accessibilityLabel("할 일 추가")
            }
            .padding(16)

            Toggle("추가 후 포스트잇 표시", isOn: $showNewTaskAsStickyNote)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(model.isSaving)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            HStack {
                Text("오늘의 목록")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                stickyManagementMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.tasks.isEmpty {
                ContentUnavailableView {
                    Label("할 일을 적어보세요", systemImage: "checklist")
                } description: {
                    Text("오늘 할 일을 하나씩 정리해 보세요.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        taskSection("할 일", tasks: model.incompleteTasks)
                        taskSection(
                            "완료", tasks: model.completedTasks,
                            topSpacing: model.incompleteTasks.isEmpty ? 0 : 24
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .transaction { $0.animation = nil }
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .sheet(item: $editingTask) { task in
            EditTaskView(model: model, task: task)
        }
        .sheet(isPresented: $showingStickyPicker) {
            StickyNotePickerView(model: model)
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
            get: { model.errorMessage != nil && editingTask == nil && !showingStickyPicker && controlActiveState == .key },
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
        .onAppear { isEntryFocused = true }
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

    @ViewBuilder
    private func taskSection(_ title: String, tasks: [TodoItem], topSpacing: CGFloat = 0) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks) { task in
                    TodoTaskRow(
                        model: model,
                        taskID: task.id,
                        edit: { editingTask = $0 },
                        delete: { deletingTask = $0 }
                    )
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(title) · \(tasks.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Divider()
                }
                .padding(.top, topSpacing)
                .padding(.bottom, 4)
            }
        }
    }

    private func addTask() {
        guard !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = newTitle
        let showAsStickyNote = showNewTaskAsStickyNote
        Task {
            if await model.add(title: title, showAsStickyNote: showAsStickyNote) {
                newTitle = ""
                showNewTaskAsStickyNote = false
            }
            isEntryFocused = true
        }
    }
}

// Resolve current data by identity so moving between sections cannot retain a stale task.
// The row also observes pending-save changes when ForEach's task values are unchanged.
private struct TodoTaskRow: View {
    @ObservedObject var model: TodoListModel
    let taskID: UUID
    let edit: (TodoItem) -> Void
    let delete: (TodoItem) -> Void

    var body: some View {
        if let task = model.tasks.first(where: { $0.id == taskID }) {
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

            Text(task.title)
                .foregroundStyle(isCompleted ? .secondary : .primary)
                .strikethrough(isCompleted, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

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
    private func taskActions(_ task: TodoItem) -> some View {
        let isBusy = model.isSaving || model.isCompleting(task.id)
        if !model.completionValue(for: task) {
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
    @State private var title: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    init(model: TodoListModel, task: TodoItem) {
        self.model = model
        self.task = task
        _title = State(initialValue: task.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("할 일 수정").font(.headline)
            TextField("할 일", text: $title, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .disabled(model.isSaving)
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
                        if await model.update(id: task.id, title: title) {
                            model.errorMessage = nil
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { model.errorMessage = nil; isFocused = true }
    }
}

struct QuickAddView: View {
    @ObservedObject var model: TodoListModel
    let onSave: () -> Void
    @State private var title = ""
    @State private var showAsStickyNote = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("할 일 추가", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(save)
                .disabled(model.isSaving)
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Toggle("추가 후 포스트잇 표시", isOn: $showAsStickyNote)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(model.isSaving)
                Spacer()
                Button("추가", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { isFocused = true }
    }

    private func save() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let submittedTitle = title
        let submittedStickyChoice = showAsStickyNote
        Task {
            if await model.add(title: submittedTitle, showAsStickyNote: submittedStickyChoice) {
                title = ""
                showAsStickyNote = false
                onSave()
            }
        }
    }
}
