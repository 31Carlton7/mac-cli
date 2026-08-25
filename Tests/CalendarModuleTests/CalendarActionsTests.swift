import XCTest
import Core
@testable import CalendarModule

final class MockCalendarStore: CalendarStore {
    var accessGranted = true
    var storedEvents: [EventItem] = []

    func requestAccess() async throws {
        if !accessGranted { throw MacError(.permissionDenied, "Calendar access not granted. Run: mac doctor") }
    }

    func calendars() async throws -> [CalendarInfo] {
        [CalendarInfo(id: "cal-1", title: "Default", kind: "event")]
    }

    func events(from: Date, to: Date, calendarName: String?) async throws -> [EventItem] {
        storedEvents.filter {
            $0.start >= from && $0.start < to && (calendarName == nil || $0.calendar == calendarName)
        }
    }

    func addEvent(_ draft: EventDraft) async throws -> EventItem {
        let item = EventItem(id: "evt-\(storedEvents.count + 1)", title: draft.title,
                             start: draft.start, end: draft.end,
                             calendar: draft.calendarName ?? "Default",
                             location: draft.location, notes: draft.notes, isAllDay: draft.isAllDay)
        storedEvents.append(item)
        return item
    }

    func updateEvent(id: String, patch: EventPatch) async throws -> EventItem {
        guard let i = storedEvents.firstIndex(where: { $0.id == id }) else {
            throw MacError(.notFound, "No event with id \(id).")
        }
        let old = storedEvents[i]
        let start = patch.start ?? old.start
        let baseDuration = old.end.timeIntervalSince(old.start)
        let end = start.addingTimeInterval(patch.duration ?? baseDuration)
        let updated = EventItem(id: old.id, title: patch.title ?? old.title, start: start, end: end,
                                calendar: old.calendar, location: patch.location ?? old.location,
                                notes: patch.notes ?? old.notes, isAllDay: old.isAllDay)
        storedEvents[i] = updated
        return updated
    }

    func deleteEvent(id: String) async throws {
        guard storedEvents.contains(where: { $0.id == id }) else {
            throw MacError(.notFound, "No event with id \(id).")
        }
        storedEvents.removeAll { $0.id == id }
    }
}

final class CalendarActionsTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    lazy var now = cal.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 10))!
    var store = MockCalendarStore()
    lazy var actions = CalendarActions(store: store, now: { self.now }, calendar: cal)

    func testAddDefaultsToOneHour() async throws {
        let event = try await actions.add(title: "Dentist", at: "tomorrow 2pm", duration: nil,
                                          calendarName: nil, location: nil, notes: nil, allDay: false)
        XCTAssertEqual(event.end.timeIntervalSince(event.start), 3_600)
        XCTAssertEqual(event.title, "Dentist")
    }

    func testListDefaultWindowSortsByStart() async throws {
        _ = try await actions.add(title: "B", at: "+2d", duration: nil, calendarName: nil,
                                  location: nil, notes: nil, allDay: false)
        _ = try await actions.add(title: "A", at: "tomorrow 9am", duration: nil, calendarName: nil,
                                  location: nil, notes: nil, allDay: false)
        let items = try await actions.list(from: nil, to: nil, calendarName: nil)
        XCTAssertEqual(items.map(\.title), ["A", "B"])
    }

    func testBadDateThrowsBadInput() async {
        do {
            _ = try await actions.add(title: "x", at: "banana", duration: nil, calendarName: nil,
                                      location: nil, notes: nil, allDay: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testEditWithNoFieldsThrowsBadInput() async {
        do {
            _ = try await actions.edit(id: "evt-1", title: nil, at: nil, duration: nil,
                                       location: nil, notes: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testDeleteUnknownIDThrowsNotFound() async {
        do {
            try await actions.delete(id: "nope")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testPermissionDeniedPropagates() async {
        store.accessGranted = false
        do {
            _ = try await actions.list(from: nil, to: nil, calendarName: nil)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }
}
