import Core
import Foundation

public struct ReminderDraft {
    public var title: String
    public var listName: String?
    public var due: Date?
    public var notes: String?
    public var priority: ReminderPriority

    public init(title: String, listName: String?, due: Date?, notes: String?,
                priority: ReminderPriority) {
        self.title = title
        self.listName = listName
        self.due = due
        self.notes = notes
        self.priority = priority
    }
}

public struct ReminderPatch {
    public var title: String?
    public var due: Date?
    public var notes: String?
    public var priority: ReminderPriority?

    public init() {}

    public var isEmpty: Bool {
        title == nil && due == nil && notes == nil && priority == nil
    }
}

public protocol ReminderStore {
    func requestAccess() async throws
    func lists() async throws -> [CalendarInfo]
    /// Returns every reminder in the given list (or all lists), completed included.
    func reminders(listName: String?) async throws -> [ReminderItem]
    func addReminder(_ draft: ReminderDraft) async throws -> ReminderItem
    func updateReminder(id: String, patch: ReminderPatch) async throws -> ReminderItem
    func setCompleted(id: String, _ completed: Bool) async throws -> ReminderItem
    func deleteReminder(id: String) async throws
}
