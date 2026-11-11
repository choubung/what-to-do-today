import SwiftUI
import WidgetKit

struct TodoWidgetEntry: TimelineEntry {
    let date: Date
    let tasks: [TodoItem]
    let totalCount: Int
    let page: Int
    let pageCount: Int
    let familyKey: String
    let errorMessage: String?

    static func placeholder(for family: WidgetFamily) -> Self {
        let now = Date()
        return Self(
            date: now,
            tasks: [
                TodoItem(id: UUID(), title: "오늘 할 일 정리하기", createdAt: now, completedAt: nil),
                TodoItem(id: UUID(), title: "잠깐 산책하기", createdAt: now, completedAt: nil),
                TodoItem(id: UUID(), title: "책 읽기", createdAt: now, completedAt: now)
            ],
            totalCount: 3,
            page: 0,
            pageCount: 1,
            familyKey: TodoWidgetState.familyKey(for: family),
            errorMessage: nil
        )
    }
}

struct TodoWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodoWidgetEntry {
        .placeholder(for: context.family)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodoWidgetEntry) -> Void) {
        completion(context.isPreview ? .placeholder(for: context.family) : entry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodoWidgetEntry>) -> Void) {
        let entry = entry(for: context.family)
        let policy: TimelineReloadPolicy = entry.errorMessage == nil
            ? .never : .after(Date().addingTimeInterval(60))
        completion(Timeline(entries: [entry], policy: policy))
    }

    private func entry(for family: WidgetFamily) -> TodoWidgetEntry {
        let familyKey = TodoWidgetState.familyKey(for: family)
        do {
            let requestedPage = TodoWidgetState.page(for: familyKey)
            let page = try TodoStore.live().fetchPage(
                index: requestedPage,
                pageSize: TodoWidgetState.pageSize(for: family)
            )
            TodoWidgetState.clampPage(page.index, ifStill: requestedPage, for: familyKey)
            return TodoWidgetEntry(
                date: Date(),
                tasks: page.tasks,
                totalCount: page.totalCount,
                page: page.index,
                pageCount: page.pageCount,
                familyKey: familyKey,
                errorMessage: TodoWidgetState.actionFailed(for: familyKey)
                    ? "저장하지 못했어요. 다시 시도해 주세요." : nil
            )
        } catch {
            return TodoWidgetEntry(
                date: Date(), tasks: [], totalCount: 0,
                page: 0, pageCount: 1, familyKey: familyKey,
                errorMessage: "목록을 불러오지 못했어요."
            )
        }
    }
}

struct TodoWidgetView: View {
    let entry: TodoWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Link(destination: URL(string: "whattodotoday://open")!) {
                    Text("할 일")
                        .font(.headline)
                }
                Spacer()
                if entry.errorMessage != nil && !entry.tasks.isEmpty {
                    Text("저장 실패 · 다시 시도")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .accessibilityLabel(entry.errorMessage ?? "저장 실패")
                } else if entry.totalCount > 0 {
                    Text("총 \(entry.totalCount)개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Link(destination: URL(string: "whattodotoday://add")!) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("할 일 추가")
            }

            if entry.tasks.isEmpty {
                emptyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entry.tasks) { task in
                        Toggle(
                            isOn: task.isCompleted,
                            intent: SetTodoCompletionIntent(
                                taskID: task.id,
                                completed: !task.isCompleted,
                                familyKey: entry.familyKey
                            )
                        ) {
                            Text(task.title)
                                .font(.subheadline)
                                .foregroundStyle(task.isCompleted ? .secondary : .primary)
                                .strikethrough(task.isCompleted)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(task.title)
                        .accessibilityValue(task.isCompleted ? "완료" : "미완료")
                    }
                }
                Spacer(minLength: 0)
            }

            HStack {
                Button(intent: ShowTodoPageIntent(page: entry.page - 1, familyKey: entry.familyKey)) {
                    Label("이전", systemImage: "chevron.left")
                }
                .disabled(entry.page == 0)
                Spacer()
                Text("\(entry.page + 1) / \(entry.pageCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(entry.pageCount)페이지 중 \(entry.page + 1)페이지")
                Spacer()
                Button(intent: ShowTodoPageIntent(page: entry.page + 1, familyKey: entry.familyKey)) {
                    HStack(spacing: 3) {
                        Text("다음")
                        Image(systemName: "chevron.right")
                    }
                }
                .disabled(entry.page + 1 >= entry.pageCount)
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
        .widgetURL(URL(string: "whattodotoday://open"))
        .containerBackground(.background, for: .widget)
    }

    private var emptyContent: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.errorMessage == nil ? "checklist" : "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(entry.errorMessage ?? "새로운 할 일을 추가해 보세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if entry.errorMessage != nil {
                Button(intent: ReloadTodoWidgetIntent(familyKey: entry.familyKey)) {
                    Label("다시 불러오기", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct TodoWidget: Widget {
    let kind = "WhatToDoTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodoWidgetProvider()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName("할 일")
        .description("할 일을 확인하고 완료하세요. 이전·다음 버튼으로 목록을 넘길 수 있어요.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct WhatToDoTodayWidgets: WidgetBundle {
    var body: some Widget {
        TodoWidget()
    }
}
