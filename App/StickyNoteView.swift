import AppKit
import SwiftUI

@MainActor
enum StickyNoteAppearance {
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.23, green: 0.21, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 0.97, blue: 0.83, alpha: 1)
    }

    static func background(for hex: String?) -> NSColor {
        guard let hex, let color = StickyNoteColor(hex: hex) else { return background }
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    static func foreground(for hex: String?) -> NSColor {
        guard let hex, let color = StickyNoteColor(hex: hex) else { return .labelColor }
        return color.usesDarkText ? .black : .white
    }

    static func hex(from color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        guard components.allSatisfy(\.isFinite) else { return nil }
        let bytes = components.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
}

struct StickyNoteView: View {
    @ObservedObject var model: TodoListModel
    let task: TodoItem
    let note: StickyNoteState
    let onHide: () -> Void
    let onComplete: () -> Void
    @State private var isChangingFontSize = false
    @State private var isEditingColor = false
    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: Double { model.effectiveStickyFontSize(for: note) }
    private var noteColorScheme: ColorScheme {
        guard let hex = note.effectiveColorHex, let color = StickyNoteColor(hex: hex) else { return colorScheme }
        return color.usesDarkText ? .light : .dark
    }

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
                            set: { value in if value { onComplete() } }
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
                            .foregroundStyle(Color(nsColor: StickyNoteAppearance.foreground(for: note.effectiveColorHex)))
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
        .foregroundStyle(Color(nsColor: StickyNoteAppearance.foreground(for: note.effectiveColorHex)))
        .background(Color(nsColor: StickyNoteAppearance.background(for: note.effectiveColorHex)))
        .environment(\.colorScheme, noteColorScheme)
        .contentShape(Rectangle())
        .contextMenu { noteContextMenu }
        .overlay(alignment: .bottomTrailing) {
            StickyNoteResizeHandle(color: StickyNoteAppearance.foreground(for: note.effectiveColorHex))
                .frame(width: 24, height: 24)
                .padding(2)
        }
        .allowsWindowActivationEvents()
        .popover(isPresented: $isEditingColor) {
            StickyNoteColorEditor(initialHex: note.colorHex, defaultLabel: "카테고리 색상", inheritedHex: note.categoryColorHex) { colorHex in
                await model.setStickyColor(id: task.id, colorHex: colorHex)
            }
            .environment(\.colorScheme, colorScheme)
        }
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
        Button("색상…", systemImage: "paintpalette") { isEditingColor = true }
            .disabled(model.isSaving || model.isCompleting(task.id))
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

struct StickyNoteColorEditor: View {
    let save: (String?) async -> Bool
    @State private var selectedHex: String?
    @State private var isSaving = false
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss

    let defaultLabel: String
    let inheritedHex: String?
    let title: String
    private var previewHex: String? { selectedHex ?? inheritedHex }

    private let presets: [(name: String, hex: String?)] = [
        ("노랑", "#FFF7D4"), ("분홍", "#FBE4E8"), ("파랑", "#E0EDFC"),
        ("민트", "#E0F3E7"), ("보라", "#ECE4FA"), ("회색", "#EBECEF")
    ]

    init(initialHex: String?, defaultLabel: String = "기본 노랑", inheritedHex: String? = nil, title: String = "포스트잇 색상", save: @escaping (String?) async -> Bool) {
        self.save = save
        self.defaultLabel = defaultLabel
        self.inheritedHex = inheritedHex
        self.title = title
        _selectedHex = State(initialValue: initialHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)

            HStack(spacing: 10) {
                ForEach(presets, id: \.name) { preset in
                    Button {
                        selectedHex = preset.hex
                    } label: {
                        Circle()
                            .fill(Color(nsColor: StickyNoteAppearance.background(for: preset.hex)))
                            .overlay { Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1) }
                            .overlay {
                                if selectedHex == preset.hex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Color(nsColor: StickyNoteAppearance.foreground(for: preset.hex)))
                                }
                            }
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(selectedHex == preset.hex ? .isSelected : [])
                    .help(preset.name)
                }
            }

            ColorPicker("사용자 지정", selection: Binding(
                get: { Color(nsColor: StickyNoteAppearance.background(for: previewHex)) },
                set: { if let hex = StickyNoteAppearance.hex(from: $0) { selectedHex = hex } }
            ), supportsOpacity: false)

            Text("할 일이 잘 보이는 색상")
                .font(.body)
                .foregroundStyle(Color(nsColor: StickyNoteAppearance.foreground(for: previewHex)))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color(nsColor: StickyNoteAppearance.background(for: previewHex)), in: RoundedRectangle(cornerRadius: 8))

            if saveFailed {
                Text("색상을 저장하지 못했어요. 다시 시도해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(defaultLabel) { selectedHex = nil }
                    .disabled(selectedHex == nil)
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("적용") {
                    isSaving = true
                    saveFailed = false
                    Task {
                        if await save(selectedHex) {
                            dismiss()
                        } else {
                            saveFailed = true
                        }
                        isSaving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .disabled(isSaving)
        .padding(20)
        .frame(width: 300)
    }
}

/// The visible grip is only 8 pt; its 24 pt target is easier to acquire.
private struct StickyNoteResizeHandle: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.gripColor = color.withAlphaComponent(0.35)
        view.needsDisplay = true
    }

    final class ResizeView: NSView {
        var gripColor = NSColor.secondaryLabelColor
        private var dragStart: (pointer: CGPoint, frame: CGRect)?
        private let resizeCursor = NSCursor.frameResize(position: .bottomRight, directions: .all)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            toolTip = "드래그해서 포스트잇 크기 조절"
            setAccessibilityLabel("포스트잇 크기 조절")
        }

        required init?(coder: NSCoder) { nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var needsPanelToBecomeKey: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            gripColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            path.lineCapStyle = .round
            for length: CGFloat in [4, 8] {
                path.move(to: CGPoint(x: bounds.maxX - 6 - length, y: bounds.minY + 6))
                path.line(to: CGPoint(x: bounds.maxX - 6, y: bounds.minY + 6 + length))
            }
            path.stroke()
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: resizeCursor) }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame)
            resizeCursor.push()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let dragStart else { return }
            let pointer = window.convertPoint(toScreen: event.locationInWindow)
            let delta = CGPoint(x: pointer.x - dragStart.pointer.x, y: pointer.y - dragStart.pointer.y)
            window.setFrame(StickyNoteLayout.resizedFrame(from: dragStart.frame, delta: delta, minimumSize: window.minSize), display: true)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragStart != nil else { return }
            mouseDragged(with: event)
            dragStart = nil
            NSCursor.pop()
            window?.invalidateCursorRects(for: self)
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
        override var needsPanelToBecomeKey: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
