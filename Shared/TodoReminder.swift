import Foundation

/// A floating local date/time. It intentionally stores no time-zone identifier.
struct ReminderLocalTime: Equatable, Codable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int

    init?(year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date) == components else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
    }

    init(date: Date, timeZone: TimeZone = .autoupdatingCurrent) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let value = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        year = value.year!
        month = value.month!
        day = value.day!
        hour = value.hour!
        minute = value.minute!
    }

    /// Gaps in a DST transition use the next valid time; repeated times use the first occurrence.
    func date(in timeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
            return nil
        }
        let beginning = calendar.startOfDay(for: noon).addingTimeInterval(-1)
        return calendar.nextDate(
            after: beginning,
            matching: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first
        )
    }
}

struct TodoReminder: Identifiable, Equatable, Sendable {
    /// The owning task's ID. One reminder exists per task.
    let id: UUID
    /// Replacing a schedule creates a new generation, so a late delivery cannot consume a new reminder.
    let generationID: UUID
    let schedule: ReminderLocalTime
    let deliveredAt: Date?

    init(id: UUID, generationID: UUID = UUID(), schedule: ReminderLocalTime, deliveredAt: Date? = nil) {
        self.id = id
        self.generationID = generationID
        self.schedule = schedule
        self.deliveredAt = deliveredAt
    }
}

struct TodoReminderCandidate: Equatable, Sendable {
    let taskID: UUID
    let title: String
    let isCompleted: Bool
    let reminder: TodoReminder
}

struct ReminderDeliveryPlan: Equatable, Sendable {
    let due: [TodoReminderCandidate]
    let nextDate: Date?

    static func make(
        candidates: [TodoReminderCandidate], now: Date,
        timeZone: TimeZone = .autoupdatingCurrent,
        alreadyDelivered: Set<UUID> = []
    ) -> Self {
        var due: [(TodoReminderCandidate, Date)] = []
        var nextDate: Date?
        for candidate in candidates {
            guard !candidate.isCompleted, candidate.reminder.deliveredAt == nil,
                  !alreadyDelivered.contains(candidate.reminder.generationID),
                  let date = candidate.reminder.schedule.date(in: timeZone) else { continue }
            if date <= now {
                due.append((candidate, date))
            } else if nextDate == nil || date < nextDate! {
                nextDate = date
            }
        }
        due.sort {
            $0.1 == $1.1 ? $0.0.taskID.uuidString < $1.0.taskID.uuidString : $0.1 < $1.1
        }
        return Self(due: due.map(\.0), nextDate: nextDate)
    }
}
