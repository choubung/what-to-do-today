import SwiftUI

struct TodoListView: View {
    @ObservedObject var model: TodoListModel
    @State private var newTitle = ""
    @State private var editingTask: TodoItem?
    @State private var deletingTask: TodoItem?
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

            Divider()

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
                List {
                    taskSection("할 일", tasks: model.incompleteTasks)
                    taskSection("완료", tasks: model.completedTasks)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .sheet(item: $editingTask) { task in
            EditTaskView(model: model, task: task)
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
            get: { model.errorMessage != nil && editingTask == nil && controlActiveState == .key },
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

    @ViewBuilder
    private func taskSection(_ title: String, tasks: [TodoItem]) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks) { task in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { task.isCompleted },
                            set: { value in Task { await model.setCompleted(task, completed: value) } }
                        )) { Text(task.title) }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel(task.title)
                        .disabled(model.isSaving)
                        .padding(.top, 2)

                        Text(task.title)
                            .foregroundStyle(task.isCompleted ? .secondary : .primary)
                            .strikethrough(task.isCompleted, color: .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        Menu {
                            Button("수정", systemImage: "pencil") { editingTask = task }
                            Button("삭제", systemImage: "trash", role: .destructive) { deletingTask = task }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 20, height: 20)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(model.isSaving)
                        .accessibilityLabel("\(task.title) 옵션")
                    }
                    .padding(.vertical, 7)
                    .contextMenu {
                        Button("수정", systemImage: "pencil") { editingTask = task }
                            .disabled(model.isSaving)
                        Button("삭제", systemImage: "trash", role: .destructive) { deletingTask = task }
                            .disabled(model.isSaving)
                    }
                }
            } header: {
                Text("\(title) · \(tasks.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    private func addTask() {
        guard !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = newTitle
        Task {
            if await model.add(title: title) { newTitle = "" }
            isEntryFocused = true
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
        Task {
            if await model.add(title: title) {
                title = ""
                onSave()
            }
        }
    }
}
