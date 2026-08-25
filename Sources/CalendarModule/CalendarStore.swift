import Core
import Foundation

public struct EventDraft {
    public var title: String
    public var start: Date
    public var end: Date
    public var calendarName: String?
    public var location: String?
    public var notes: String?
    public var isAllDay: Bool

    public init(title: String, start: Date, end: Date, calendarName: String?,
                location: String?, notes: String?, isAllDay: Bool) {
        self.title = title
        self.start = start
        self.end = end
        self.calendarName = calendarName
        self.location = location
        self.notes = notes
        self.isAllDay = isAllDay
    }
}

public struct EventPatch {
    public var title: String?
    public var start: Date?
    public var duration: TimeInterval?
    public var location: String?
    public var notes: String?

    public init() {}

    public var isEmpty: Bool {
        title == nil && start == nil && duration == nil && location == nil && notes == nil
    }
}

public protocol CalendarStore {
    func requestAccess() async throws
    func calendars() async throws -> [CalendarInfo]
    func events(from: Date, to: Date, calendarName: String?) async throws -> [EventItem]
    func addEvent(_ draft: EventDraft) async throws -> EventItem
    func updateEvent(id: String, patch: EventPatch) async throws -> EventItem
    func deleteEvent(id: String) async throws
}
