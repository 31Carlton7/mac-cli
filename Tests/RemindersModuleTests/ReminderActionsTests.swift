import XCTest
import Core
@testable import RemindersModule

final class MockReminderStore: ReminderStore {
    var accessGranted = true
    var knownLists = ["Reminders"]
    var stored: [ReminderItem] = []

    func requestAccess() async throws {
        if !accessGranted { throw MacError(.permissionDenied, "Reminders access not granted. Run: mac doctor") }
    }

    private func validate(_ listName: String?) throws {
        if let name = listName, !knownLists.contains(name) {
            throw MacError(.notFound, "No reminder list named '\(name)'. Run: mac reminders lists")
        }
    }

    func lists() async throws -> [CalendarInfo] {
        knownLists.enumerated().map { CalendarInfo(id: "list-\($0.offset + 1)", title: $0.element, kind: "reminder") }
    }

    func reminders(listName: String?) async throws -> [ReminderItem] {
        try validate(listName)
        return stored.filter { listName == nil || $0.list == listName }
    }

    func addReminder(_ draft: ReminderDraft) async throws -> ReminderItem {
        try validate(draft.listName)
        let item = ReminderItem(id: "rem-\(stored.count + 1)", title: draft.title,
                                list: draft.listName ?? "Reminders", due: draft.due,
                                notes: draft.notes, priority: draft.priority, isCompleted: false)
        stored.append(item)
        return item
    }

    func updateReminder(id: String, patch: ReminderPatch) async throws -> ReminderItem {
        guard let i = stored.firstIndex(where: { $0.id == id }) else {
            throw MacError(.notFound, "No reminder with id \(id).")
        }
        let old = stored[i]
        let updated = ReminderItem(id: old.id, title: patch.title ?? old.title, list: old.list,
                                   due: patch.due ?? old.due, notes: patch.notes ?? old.notes,
                                   priority: patch.priority ?? old.priority,
                                   isCompleted: old.isCompleted)
        stored[i] = updated
        return updated
    }

    func setCompleted(id: String, _ completed: Bool) async throws -> ReminderItem {
        guard let i = stored.firstIndex(where: { $0.id == id }) else {
            throw MacError(.notFound, "No reminder with id \(id).")
        }
        let old = stored[i]
        let updated = ReminderItem(id: old.id, title: old.title, list: old.list, due: old.due,
                                   notes: old.notes, priority: old.priority, isCompleted: completed)
        stored[i] = updated
        return updated
    }

    func deleteReminder(id: String) async throws {
        guard stored.contains(where: { $0.id == id }) else {
            throw MacError(.notFound, "No reminder with id \(id).")
        }
        stored.removeAll { $0.id == id }
    }
}

final class ReminderActionsTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    lazy var now = cal.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 10))!
    var store = MockReminderStore()
    lazy var actions = ReminderActions(store: store, now: { self.now }, calendar: cal)

    func testListHidesCompletedByDefaultAndSortsByDue() async throws {
        _ = try await actions.add(title: "later", listName: nil, due: "+2d", notes: nil, priority: .none)
        _ = try await actions.add(title: "soon", listName: nil, due: "tomorrow 9am", notes: nil, priority: .none)
        let done = try await actions.add(title: "done", listName: nil, due: nil, notes: nil, priority: .none)
        _ = try await actions.complete(id: done.id)

        let visible = try await actions.list(listName: nil, includeCompleted: false, dueBefore: nil)
        XCTAssertEqual(visible.map(\.title), ["soon", "later"])

        let all = try await actions.list(listName: nil, includeCompleted: true, dueBefore: nil)
        XCTAssertEqual(all.count, 3)
    }

    func testDueBeforeFilters() async throws {
        _ = try await actions.add(title: "near", listName: nil, due: "tomorrow 9am", notes: nil, priority: .none)
        _ = try await actions.add(title: "far", listName: nil, due: "+6d", notes: nil, priority: .none)
        let items = try await actions.list(listName: nil, includeCompleted: false, dueBefore: "+2d")
        XCTAssertEqual(items.map(\.title), ["near"])
    }

    func testCompleteSetsFlag() async throws {
        let item = try await actions.add(title: "x", listName: nil, due: nil, notes: nil, priority: .none)
        let completed = try await actions.complete(id: item.id)
        XCTAssertTrue(completed.isCompleted)
    }

    func testBadDueDateThrowsBadInput() async {
        do {
            _ = try await actions.add(title: "x", listName: nil, due: "banana", notes: nil, priority: .none)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testEditWithNoFieldsThrowsBadInput() async {
        do {
            _ = try await actions.edit(id: "rem-1", title: nil, due: nil, notes: nil, priority: nil)
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

    func testUnknownListNameThrowsNotFound() async {
        do {
            _ = try await actions.add(title: "x", listName: "Bogus", due: nil, notes: nil, priority: .none)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }
}
