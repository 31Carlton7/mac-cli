import Core
import EventKit
import Foundation

public final class EventKitReminderStore: ReminderStore {
    let store = EKEventStore()

    public init() {}

    static let deniedError = MacError(
        .permissionDenied,
        "Reminders access not granted. Enable it in System Settings > Privacy & Security > Reminders for your terminal app, or run: mac doctor"
    )

    public func requestAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToReminders()) ?? false
            if !granted { throw Self.deniedError }
        default:
            throw Self.deniedError
        }
    }

    public func lists() async throws -> [CalendarInfo] {
        store.calendars(for: .reminder).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, kind: "reminder")
        }
    }

    public func reminders(listName: String?) async throws -> [ReminderItem] {
        let calendars = try listName.map { [try findList(named: $0)] }
        let predicate = store.predicateForReminders(in: calendars)
        let fetched: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        return fetched.map(Self.item)
    }

    public func addReminder(_ draft: ReminderDraft) async throws -> ReminderItem {
        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.priority = draft.priority.ekValue
        reminder.calendar = try draft.listName.map { try findList(named: $0) }
            ?? store.defaultCalendarForNewReminders()
        if let due = draft.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    public func updateReminder(id: String, patch: ReminderPatch) async throws -> ReminderItem {
        let reminder = try find(id)
        if let title = patch.title { reminder.title = title }
        if let due = patch.due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        if let notes = patch.notes { reminder.notes = notes }
        if let priority = patch.priority { reminder.priority = priority.ekValue }
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    public func setCompleted(id: String, _ completed: Bool) async throws -> ReminderItem {
        let reminder = try find(id)
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    public func deleteReminder(id: String) async throws {
        try store.remove(try find(id), commit: true)
    }

    func find(_ id: String) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw MacError(.notFound, "No reminder with id \(id).")
        }
        return reminder
    }

    func findList(named name: String) throws -> EKCalendar {
        guard let list = store.calendars(for: .reminder).first(where: { $0.title == name }) else {
            throw MacError(.notFound, "No reminder list named '\(name)'. Run: mac reminders lists")
        }
        return list
    }

    static func item(_ r: EKReminder) -> ReminderItem {
        ReminderItem(id: r.calendarItemIdentifier, title: r.title ?? "",
                     list: r.calendar?.title ?? "",
                     due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                     notes: r.notes, priority: ReminderPriority(ekValue: r.priority),
                     isCompleted: r.isCompleted)
    }
}
