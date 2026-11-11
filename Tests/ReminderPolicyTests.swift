import Foundation

@main
private enum ReminderPolicyTests {
    static func main() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        let london = TimeZone(identifier: "Europe/London")!
        let ny = TimeZone(identifier: "America/New_York")!
        let schedule = ReminderLocalTime(year: 2026, month: 11, day: 11, hour: 9, minute: 0)!
        precondition(schedule.date(in: london)!.timeIntervalSince(schedule.date(in: seoul)!) == 9 * 3600)
        precondition(ReminderLocalTime(year: 2026, month: 2, day: 30, hour: 9, minute: 0) == nil)
        let gap = ReminderLocalTime(year: 2026, month: 3, day: 8, hour: 2, minute: 30)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ny
        let gapComponents = calendar.dateComponents([.hour, .minute], from: gap.date(in: ny)!)
        precondition(gapComponents.hour == 3 && gapComponents.minute == 0)
        let repeated = ReminderLocalTime(year: 2026, month: 11, day: 1, hour: 1, minute: 30)!
        precondition(ny.secondsFromGMT(for: repeated.date(in: ny)!) == -4 * 3600)

        let now = schedule.date(in: seoul)!
        let late = candidate(title: "late", date: now.addingTimeInterval(-3600), zone: seoul)
        let due = candidate(title: "now", date: now, zone: seoul)
        let future = candidate(title: "future", date: now.addingTimeInterval(60), zone: seoul)
        let complete = candidate(title: "complete", date: now, zone: seoul, completed: true)
        let delivered = candidate(title: "delivered", date: now, zone: seoul, deliveredAt: now)
        let plan = ReminderDeliveryPlan.make(candidates: [future, due, late, complete, delivered], now: now, timeZone: seoul)
        precondition(plan.due.map(\.title) == ["late", "now"], "Overdue incomplete reminders form one ordered batch")
        precondition(plan.nextDate == now.addingTimeInterval(60))
        let repeatedPlan = ReminderDeliveryPlan.make(
            candidates: [late, due], now: now, timeZone: seoul,
            alreadyDelivered: Set(plan.due.map { $0.reminder.generationID })
        )
        precondition(repeatedPlan.due.isEmpty && repeatedPlan.nextDate == nil)

        // Time spent asleep advances the clock across multiple deadlines; one plan contains all of them.
        let beforeSleep = ReminderDeliveryPlan.make(candidates: [late, due, future], now: now.addingTimeInterval(-7200), timeZone: seoul)
        precondition(beforeSleep.due.isEmpty && beforeSleep.nextDate == now.addingTimeInterval(-3600))
        let afterWake = ReminderDeliveryPlan.make(candidates: [late, due, future], now: now.addingTimeInterval(7200), timeZone: seoul)
        precondition(afterWake.due.count == 3 && afterWake.nextDate == nil)

        // Rescheduling the same task creates a new generation that a previous delivery cannot suppress.
        let replacement = TodoReminderCandidate(
            taskID: due.taskID, title: due.title, isCompleted: false,
            reminder: TodoReminder(id: due.taskID, schedule: due.reminder.schedule)
        )
        let replacementPlan = ReminderDeliveryPlan.make(
            candidates: [replacement], now: now, timeZone: seoul,
            alreadyDelivered: [due.reminder.generationID]
        )
        precondition(replacementPlan.due == [replacement])
        print("ReminderPolicyTests passed")
    }

    private static func candidate(
        title: String, date: Date, zone: TimeZone, completed: Bool = false, deliveredAt: Date? = nil
    ) -> TodoReminderCandidate {
        let id = UUID()
        return TodoReminderCandidate(
            taskID: id, title: title, isCompleted: completed,
            reminder: TodoReminder(id: id, schedule: ReminderLocalTime(date: date, timeZone: zone), deliveredAt: deliveredAt)
        )
    }
}
