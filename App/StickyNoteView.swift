import AppKit
import SwiftUI

@MainActor
enum StickyNoteAppearance {
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.23, green: 0.21, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 0.97, blue: 0.83, alpha: 1)
    }
}

struct StickyNoteView: View {
    @ObservedObject var model: TodoListModel
    let task: TodoItem
    let note: StickyNoteState
    let onHide: () -> Void
    @State private var isChangingFontSize = false

    private var fontSize: Double { model.effectiveStickyFontSize(for: note) }

    var body: some View {
        VStack(spacing: 0) {
            StickyNoteDragArea()
                .frame(height: 24)
                .overlay {
                    Capsule()
                        .fill(.secondary.opacity(0.3))
                        .frame(width: 30, height: 4)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 6)

            VStack(alignment: .leading, spacing: 12) {
                controls

                ScrollView {
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("완료", isOn: Binding(
                            get: { model.completionValue(for: task) },
                            set: { value in Task { await model.setCompleted(task, completed: value) } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .padding(.top, max(2, (fontSize - 14) / 2))
                        .disabled(model.isSaving || model.isCompleting(task.id))
                        .accessibilityLabel("\(task.title) 완료")

                        Text(task.title)
                            .font(.system(size: fontSize, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .contextMenu { noteContextMenu }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: StickyNoteAppearance.background))
        .contentShape(Rectangle())
        .contextMenu { noteContextMenu }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Spacer()

            Menu {
                noteContextMenu
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("포스트잇 설정")
            .help("포스트잇 설정")

            Button {
                Task { _ = await model.setStickyAlwaysOnTop(id: task.id, value: !note.isAlwaysOnTop) }
            } label: {
                Image(systemName: note.isAlwaysOnTop ? "pin.fill" : "pin")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(note.isAlwaysOnTop ? "항상 위에 표시 끄기" : "항상 위에 표시 켜기")
            .help(note.isAlwaysOnTop ? "항상 위에 표시 끄기" : "항상 위에 표시 켜기")

            Button(action: onHide) {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("포스트잇 숨기기")
            .help("할 일을 완료하지 않고 포스트잇만 숨기기")
        }
        .font(.callout)
        .disabled(model.isSaving || model.isCompleting(task.id))
    }

    @ViewBuilder
    private var noteContextMenu: some View {
        Menu("글자 크기") {
            fontSizeMenuContents
        }
        Divider()
        Button("할 일 내용 복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.title, forType: .string)
        }
    }

    @ViewBuilder
    private var fontSizeMenuContents: some View {
        Text("글자 크기: \(fontSize.formatted()) pt\(note.fontSize == nil ? " (공통)" : "")")
        Divider()
        Group {
            Button("작게") {
                changeFontSize(max(
                    StickyNoteTypography.minimumFontSize,
                    fontSize - StickyNoteTypography.fontSizeStep
                ))
            }
            .disabled(fontSize <= StickyNoteTypography.minimumFontSize)

            Button("크게") {
                changeFontSize(min(
                    StickyNoteTypography.maximumFontSize,
                    fontSize + StickyNoteTypography.fontSizeStep
                ))
            }
            .disabled(fontSize >= StickyNoteTypography.maximumFontSize)

            Divider()
            Button {
                changeFontSize(nil)
            } label: {
                if note.fontSize == nil {
                    Label("공통 설정 따르기 (\(model.defaultStickyFontSize.formatted()) pt)", systemImage: "checkmark")
                } else {
                    Text("공통 설정 따르기 (\(model.defaultStickyFontSize.formatted()) pt)")
                }
            }
            .disabled(note.fontSize == nil)
        }
        .disabled(isChangingFontSize || model.isSaving || model.isCompleting(task.id))
    }

    private func changeFontSize(_ fontSize: Double?) {
        guard !isChangingFontSize else { return }
        isChangingFontSize = true
        Task {
            await model.setStickyFontSize(id: task.id, fontSize: fontSize)
            isChangingFontSize = false
        }
    }
}

/// Restrict moving to the top strip so selecting text and using controls never drag the note.
private struct StickyNoteDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            toolTip = "여기를 드래그해서 포스트잇 이동"
            setAccessibilityLabel("포스트잇 이동")
        }

        required init?(coder: NSCoder) { nil }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
