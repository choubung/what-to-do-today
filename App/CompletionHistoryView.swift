import SwiftUI

/// History is loaded a month at a time and never becomes part of today's task list.
struct CompletionHistoryView: View {
    @ObservedObject var model: TodoListModel
    @Environment(\.dismiss) private var dismiss
    @State private var categoryID: UUID?
    @State private var displayedMonthComponents: DateComponents
    @State private var selectedDayComponents: DateComponents
    @State private var tasks: [TodoItem] = []
    @State private var loadedRequest: HistoryRequest?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var deletingTask: TodoItem?
    @State private var restoreNotice: String?
    @State private var retry = 0

    init(model: TodoListModel, initialCategoryID: UUID?) {
        self.model = model
        let calendar = Calendar.autoupdatingCurrent
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        _categoryID = State(initialValue: initialCategoryID)
        _selectedDayComponents = State(initialValue: calendar.dateComponents([.year, .month, .day], from: yesterday))
        _displayedMonthComponents = State(initialValue: calendar.dateComponents([.year, .month], from: yesterday))
    }

    private var calendar: Calendar { .autoupdatingCurrent }
    // Keep civil dates so a time-zone change does not move the chosen month or day.
    private var displayedMonth: Date { calendar.date(from: displayedMonthComponents)! }
    private var selectedDay: Date { calendar.date(from: selectedDayComponents)! }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var monthRange: DateInterval { calendar.dateInterval(of: .month, for: displayedMonth)! }
    private var request: HistoryRequest {
        HistoryRequest(
            month: monthRange, today: today, categoryID: categoryID,
            timeZone: calendar.timeZone.identifier, revision: model.completionHistoryRevision, retry: retry
        )
    }
    private var currentTasks: [TodoItem] { loadedRequest == request ? tasks : [] }
    private var selectedTasks: [TodoItem] {
        currentTasks.filter { task in
            task.completedAt.map { calendar.isDate($0, inSameDayAs: selectedDay) } ?? false
        }
    }
    private var completedCounts: [Date: Int] {
        currentTasks.reduce(into: [:]) { counts, task in
            if let completedAt = task.completedAt { counts[calendar.startOfDay(for: completedAt), default: 0] += 1 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("이전 완료", systemImage: "calendar")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("카테고리", selection: $categoryID) {
                Text("전체").tag(UUID?.none)
                ForEach(model.categories) { category in
                    Text(category.name).tag(Optional(category.id))
                }
            }
            .pickerStyle(.menu)
            monthNavigation
            calendarGrid
            Text("오늘 완료한 항목은 오늘의 목록에서 볼 수 있어요.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text(selectedDay, format: .dateTime.month().day().weekday(.wide))
                    .font(.headline)
                Spacer()
                if !isLoading && loadedRequest == request {
                    Text("\(selectedTasks.count)개 완료").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let restoreNotice {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                    Text(restoreNotice).lineLimit(2)
                    Spacer(minLength: 0)
                    Button { self.restoreNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("복원 안내 닫기")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            historyList
        }
        .padding(20)
        .frame(width: 440, height: 650)
        .task(id: request) { await load(request) }
        .onChange(of: categoryID) { _, _ in restoreNotice = nil }
        .onChange(of: model.categories) { _, categories in
            if let categoryID, !categories.contains(where: { $0.id == categoryID }) { self.categoryID = nil }
        }
        .onChange(of: today) { _, newToday in
            if selectedDay >= newToday {
                let yesterday = calendar.date(byAdding: .day, value: -1, to: newToday)!
                selectedDayComponents = calendar.dateComponents([.year, .month, .day], from: yesterday)
                displayedMonthComponents = calendar.dateComponents([.year, .month], from: yesterday)
            }
        }
        .confirmationDialog("완료 기록을 삭제할까요?", isPresented: Binding(
            get: { deletingTask != nil }, set: { if !$0 { deletingTask = nil } }
        ), titleVisibility: .visible, presenting: deletingTask) { task in
            Button("삭제", role: .destructive) {
                Task { _ = await model.delete(task) }
            }
            .disabled(model.isSaving || model.isCompleting(task.id))
            Button("취소", role: .cancel) { deletingTask = nil }
        } message: { task in
            Text(task.title)
        }
        .alert("처리하지 못했어요", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var monthNavigation: some View {
        HStack {
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("이전 달")
            Spacer()
            Text(displayedMonth, format: .dateTime.year().month(.wide))
                .font(.headline)
            Spacer()
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                .disabled(monthRange.end >= today)
                .accessibilityLabel("다음 달")
        }
        .buttonStyle(.borderless)
    }

    private var calendarGrid: some View {
        let firstWeekday = calendar.component(.weekday, from: monthRange.start)
        let leadingDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: monthRange.start)!.count
        let cellCount = ((leadingDays + dayCount + 6) / 7) * 7
        let weekdayNames = calendar.veryShortStandaloneWeekdaySymbols
        let counts = completedCounts
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
            ForEach(0..<7, id: \.self) { index in
                Text(weekdayNames[(calendar.firstWeekday - 1 + index) % 7])
                    .font(.caption).foregroundStyle(.secondary).frame(height: 20)
            }
            ForEach(0..<cellCount, id: \.self) { index in
                let day = index - leadingDays + 1
                if day > 0 && day <= dayCount,
                   let date = calendar.date(byAdding: .day, value: day - 1, to: monthRange.start) {
                    dayButton(day, date: date, count: counts[calendar.startOfDay(for: date), default: 0])
                } else {
                    Color.clear.frame(height: 35).accessibilityHidden(true)
                }
            }
        }
    }

    private func dayButton(_ day: Int, date: Date, count: Int) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selectedDay)
        return Button {
            selectedDayComponents = calendar.dateComponents([.year, .month, .day], from: date)
            restoreNotice = nil
        } label: {
            VStack(spacing: 3) {
                Text("\(day)").font(.callout).monospacedDigit()
                Circle().fill(count > 0 ? (selected ? Color.white : Color.accentColor) : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity).frame(height: 35)
            .foregroundStyle(selected ? Color.white : date < today ? Color.primary : Color.secondary.opacity(0.45))
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(date >= today)
        .accessibilityLabel("\(date.formatted(.dateTime.year().month().day())), \(count)개 완료")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var historyList: some View {
        if isLoading || (loadedRequest != request && loadError == nil) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 10) {
                Text(loadError).foregroundStyle(.secondary)
                Button("다시 불러오기") { retry += 1 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedTasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "calendar").font(.title2).foregroundStyle(.secondary)
                Text("이날 완료한 항목이 없어요.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(selectedTasks) { task in
                        historyRow(task)
                        Divider()
                    }
                }
            }
        }
    }

    private func historyRow(_ task: TodoItem) -> some View {
        let isBusy = model.isSaving || model.isCompleting(task.id)
        return HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.completionValue(for: task) },
                set: { value in if !value { restore(task) } }
            )) { Text(task.title) }
            .toggleStyle(.checkbox).labelsHidden().padding(.top, 2)
            .accessibilityLabel("\(task.title) 완료")
            .help("완료를 취소하고 오늘의 할 일로 되돌리기")
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title).strikethrough().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let categoryName = model.categoryName(for: task) {
                        Text(categoryName).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let completedAt = task.completedAt {
                        Text(completedAt, format: .dateTime.hour().minute())
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Menu {
                Button("할 일로 되돌리기", systemImage: "arrow.uturn.backward") { restore(task) }
                Button("삭제", systemImage: "trash", role: .destructive) { deletingTask = task }
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("\(task.title) 메뉴")
        }
        .disabled(isBusy)
        .padding(.vertical, 10)
    }

    private func moveMonth(_ offset: Int) {
        guard let newMonth = calendar.date(byAdding: .month, value: offset, to: monthRange.start),
              newMonth < today else { return }
        displayedMonthComponents = calendar.dateComponents([.year, .month], from: newMonth)
        let nextMonth = calendar.dateInterval(of: .month, for: newMonth)!
        let latestDay = calendar.date(byAdding: .day, value: -1, to: min(nextMonth.end, today))!
        let dayOffset = min(calendar.component(.day, from: selectedDay), calendar.component(.day, from: latestDay)) - 1
        let newSelection = calendar.date(byAdding: .day, value: dayOffset, to: nextMonth.start)!
        selectedDayComponents = calendar.dateComponents([.year, .month, .day], from: newSelection)
        restoreNotice = nil
    }

    private func restore(_ task: TodoItem) {
        Task {
            if await model.setCompleted(task, completed: false) {
                restoreNotice = "‘\(task.title)’ 항목을 오늘의 할 일로 되돌렸어요."
            }
        }
    }

    private func load(_ requested: HistoryRequest) async {
        isLoading = true
        loadError = nil
        do {
            let end = min(requested.month.end, requested.today)
            let result = end > requested.month.start
                ? try await model.completedTasks(
                    in: DateInterval(start: requested.month.start, end: end), categoryID: requested.categoryID
                ) : []
            guard !Task.isCancelled, requested == request else { return }
            tasks = result
            loadedRequest = requested
            isLoading = false
        } catch {
            guard !Task.isCancelled, requested == request else { return }
            tasks = []
            loadedRequest = requested
            loadError = "완료 기록을 불러오지 못했어요. 다시 시도해 주세요."
            isLoading = false
        }
    }
}

private struct HistoryRequest: Equatable {
    let month: DateInterval
    let today: Date
    let categoryID: UUID?
    let timeZone: String
    let revision: UInt
    let retry: Int
}
