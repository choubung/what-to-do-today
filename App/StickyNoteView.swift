import SwiftUI

struct StickyNoteView: View {
    @ObservedObject var model: TodoListModel
    let task: TodoItem
    let note: StickyNoteState
    let onHide: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Toggle("완료", isOn: Binding(
                    get: { task.isCompleted },
                    set: { value in Task { await model.setCompleted(task, completed: value) } }
                ))
                .toggleStyle(.checkbox)
                .disabled(model.isSaving)
                .accessibilityLabel("\(task.title) 완료")

                Spacer()

                Button {
                    Task { _ = await model.setStickyAlwaysOnTop(id: task.id, value: !note.isAlwaysOnTop) }
                } label: {
                    Image(systemName: note.isAlwaysOnTop ? "pin.fill" : "pin")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(model.isSaving)
                .accessibilityLabel(note.isAlwaysOnTop ? "항상 위에 표시 끄기" : "항상 위에 표시 켜기")
                .help(note.isAlwaysOnTop ? "항상 위에 표시 끄기" : "항상 위에 표시 켜기")

                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(model.isSaving)
                .accessibilityLabel("포스트잇 숨기기")
                .help("할 일을 완료하지 않고 포스트잇만 숨기기")
            }
            .font(.callout)

            ScrollView {
                Text(task.title)
                    .font(.system(size: 17, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    Button("확인") { model.errorMessage = nil }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .background(colorScheme == .dark
                    ? Color(red: 0.23, green: 0.21, blue: 0.14)
                    : Color(red: 1.0, green: 0.97, blue: 0.83))
    }
}
