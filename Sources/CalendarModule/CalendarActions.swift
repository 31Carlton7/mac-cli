import Core
import Foundation

public struct CalendarActions {
    let store: CalendarStore
    let now: () -> Date
    let calendar: Calendar

    public init(store: CalendarStore, now: @escaping () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.store = store
        self.now = now
        self.calendar = calendar
    }

    public func list(from: String?, to: String?, calendarName: String?) async throws -> [EventItem] {
        try await store.requestAccess()
        let fromDate = try resolve(from ?? "today", flag: "--from")
        let toDate = try resolve(to ?? "+7d", flag: "--to")
        let items = try await store.events(from: fromDate, to: toDate, calendarName: calendarName)
        return items.sorted { $0.start < $1.start }
    }

    public func add(title: String, at: String, duration: String?, calendarName: String?,
                    location: String?, notes: String?, allDay: Bool) async throws -> EventItem {
        try await store.requestAccess()
        let start = try resolve(at, flag: "--at")
        let seconds = try duration.map(parseDuration) ?? 3_600
        let realStart = allDay ? calendar.startOfDay(for: start) : start
        let end: Date
        if allDay {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: realStart) else {
                throw MacError(.badInput, "Could not compute all-day event end for '\(at)'.")
            }
            end = nextDay
        } else {
            end = realStart.addingTimeInterval(seconds)
        }
        let draft = EventDraft(title: title, start: realStart, end: end, calendarName: calendarName,
                               location: location, notes: notes, isAllDay: allDay)
        return try await store.addEvent(draft)
    }

    public func edit(id: String, title: String?, at: String?, duration: String?,
                     location: String?, notes: String?) async throws -> EventItem {
        try await store.requestAccess()
        var patch = EventPatch()
        patch.title = title
        patch.start = try at.map { try resolve($0, flag: "--at") }
        patch.duration = try duration.map(parseDuration)
        patch.location = location
        patch.notes = notes
        guard !patch.isEmpty else {
            throw MacError(.badInput, "Nothing to change. Pass at least one of --title, --at, --duration, --location, --notes.")
        }
        return try await store.updateEvent(id: id, patch: patch)
    }

    public func delete(id: String) async throws {
        try await store.requestAccess()
        try await store.deleteEvent(id: id)
    }

    public func calendars() async throws -> [CalendarInfo] {
        try await store.requestAccess()
        return try await store.calendars()
    }

    func resolve(_ text: String, flag: String) throws -> Date {
        guard let date = DateParser.parse(text, now: now(), calendar: calendar) else {
            throw MacError(.badInput, "Could not parse date '\(text)' for \(flag). Try 'today', 'tomorrow 2pm', '+7d', or '2026-08-27 14:00'.")
        }
        return date
    }

    func parseDuration(_ text: String) throws -> TimeInterval {
        guard let seconds = DurationParser.parse(text) else {
            throw MacError(.badInput, "Could not parse duration '\(text)'. Try 1h, 30m, or 1h30m.")
        }
        return seconds
    }
}
