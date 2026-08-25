import Core
import Foundation

public struct ReminderActions {
    let store: ReminderStore
    let now: () -> Date
    let calendar: Calendar

    public init(store: ReminderStore, now: @escaping () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    public func list(listName: String?, includeCompleted: Bool,
                     dueBefore: String?) async throws -> [ReminderItem] {
        try await store.requestAccess()
        let cutoff = try dueBefore.map { try resolve($0, flag: "--due-before") }
        return try await store.reminders(listName: listName)
            .filter { includeCompleted || !$0.isCompleted }
            .filter { cutoff == nil || ($0.due != nil && $0.due! < cutoff!) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    public func add(title: String, listName: String?, due: String?, notes: String?,
                    priority: ReminderPriority) async throws -> ReminderItem {
        try await store.requestAccess()
        let dueDate = try due.map { try resolve($0, flag: "--due") }
        let draft = ReminderDraft(title: title, listName: listName, due: dueDate,
                                  notes: notes, priority: priority)
        return try await store.addReminder(draft)
    }

    public func complete(id: String) async throws -> ReminderItem {
        try await store.requestAccess()
        return try await store.setCompleted(id: id, true)
    }

    public func edit(id: String, title: String?, due: String?, notes: String?,
                     priority: ReminderPriority?) async throws -> ReminderItem {
        try await store.requestAccess()
        var patch = ReminderPatch()
        patch.title = title
        patch.due = try due.map { try resolve($0, flag: "--due") }
        patch.notes = notes
        patch.priority = priority
        guard !patch.isEmpty else {
            throw MacError(.badInput, "Nothing to change. Pass at least one of --title, --due, --notes, --priority.")
        }
        return try await store.updateReminder(id: id, patch: patch)
    }

    public func delete(id: String) async throws {
        try await store.requestAccess()
        try await store.deleteReminder(id: id)
    }

    public func lists() async throws -> [CalendarInfo] {
        try await store.requestAccess()
        return try await store.lists()
    }

    func resolve(_ text: String, flag: String) throws -> Date {
        guard let date = DateParser.parse(text, now: now(), calendar: calendar) else {
            throw MacError(.badInput, "Could not parse date '\(text)' for \(flag). Try 'today', 'tomorrow 9am', '+7d', or '2026-08-27 14:00'.")
        }
        return date
    }
}
