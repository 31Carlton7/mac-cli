import Core
import EventKit
import Foundation

public final class EventKitCalendarStore: CalendarStore {
    let store = EKEventStore()

    public init() {}

    static let deniedError = MacError(
        .permissionDenied,
        "Calendar access not granted. Enable it in System Settings > Privacy & Security > Calendars for your terminal app, or run: mac doctor"
    )

    public func requestAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            if !granted { throw Self.deniedError }
        default:
            throw Self.deniedError
        }
    }

    public func calendars() async throws -> [CalendarInfo] {
        store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, kind: "event")
        }
    }

    public func events(from: Date, to: Date, calendarName: String?) async throws -> [EventItem] {
        let calendars = try calendarName.map { [try findCalendar(named: $0)] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).map(Self.item)
    }

    public func addEvent(_ draft: EventDraft) async throws -> EventItem {
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        event.notes = draft.notes
        event.calendar = try draft.calendarName.map { try findCalendar(named: $0) }
            ?? store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        return Self.item(event)
    }

    public func updateEvent(id: String, patch: EventPatch) async throws -> EventItem {
        let event = try find(id)
        if let title = patch.title { event.title = title }
        if let start = patch.start {
            let existing = event.endDate.timeIntervalSince(event.startDate)
            event.startDate = start
            event.endDate = start.addingTimeInterval(existing)
        }
        if let duration = patch.duration {
            event.endDate = event.startDate.addingTimeInterval(duration)
        }
        if let location = patch.location { event.location = location }
        if let notes = patch.notes { event.notes = notes }
        try store.save(event, span: .thisEvent, commit: true)
        return Self.item(event)
    }

    public func deleteEvent(id: String) async throws {
        try store.remove(try find(id), span: .thisEvent, commit: true)
    }

    func find(_ id: String) throws -> EKEvent {
        guard let event = store.calendarItem(withIdentifier: id) as? EKEvent else {
            throw MacError(.notFound, "No event with id \(id).")
        }
        return event
    }

    func findCalendar(named name: String) throws -> EKCalendar {
        guard let calendar = store.calendars(for: .event).first(where: { $0.title == name }) else {
            throw MacError(.notFound, "No calendar named '\(name)'. Run: mac calendar calendars")
        }
        return calendar
    }

    static func item(_ e: EKEvent) -> EventItem {
        EventItem(id: e.calendarItemIdentifier, title: e.title ?? "", start: e.startDate,
                  end: e.endDate, calendar: e.calendar?.title ?? "", location: e.location,
                  notes: e.notes, isAllDay: e.isAllDay)
    }
}
