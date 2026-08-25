import XCTest
@testable import Core

final class ModelsTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_787_824_800) // 2026-08-27T10:00:00Z

    func testEventItemJSONSchema() throws {
        let event = EventItem(id: "e1", title: "Dentist", start: start,
                              end: start.addingTimeInterval(3_600), calendar: "Personal",
                              location: nil, notes: nil, isAllDay: false)
        let json = String(data: try Output.encoder.encode(event), encoding: .utf8)!
        XCTAssertEqual(json, #"{"calendar":"Personal","end":"2026-08-27T11:00:00Z","id":"e1","isAllDay":false,"start":"2026-08-27T10:00:00Z","title":"Dentist"}"#)
    }

    func testReminderItemJSONSchema() throws {
        let reminder = ReminderItem(id: "r1", title: "Buy milk", list: "Groceries",
                                    due: start, notes: nil, priority: .high, isCompleted: false)
        let json = String(data: try Output.encoder.encode(reminder), encoding: .utf8)!
        XCTAssertEqual(json, #"{"due":"2026-08-27T10:00:00Z","id":"r1","isCompleted":false,"list":"Groceries","priority":"high","title":"Buy milk"}"#)
    }

    func testContactItemJSONSchema() throws {
        let contact = ContactItem(id: "c1", name: "Sarah Chen", organization: nil,
                                  phones: ["+15551234567"], emails: ["sarah@example.com"])
        let json = String(data: try Output.encoder.encode(contact), encoding: .utf8)!
        XCTAssertEqual(json, #"{"emails":["sarah@example.com"],"id":"c1","name":"Sarah Chen","phones":["+15551234567"]}"#)
    }

    func testHumanLinesStartWithIDAndTitle() {
        let event = EventItem(id: "e1", title: "Dentist", start: start, end: start,
                              calendar: "Personal", location: nil, notes: nil, isAllDay: false)
        XCTAssertTrue(event.humanLine.hasPrefix("e1  Dentist  "))
        let list = CalendarInfo(id: "cal1", title: "Personal", kind: "event")
        XCTAssertEqual(list.humanLine, "cal1  Personal")
    }

    func testPriorityEKValueRoundTrip() {
        XCTAssertEqual(ReminderPriority.high.ekValue, 1)
        XCTAssertEqual(ReminderPriority.medium.ekValue, 5)
        XCTAssertEqual(ReminderPriority.low.ekValue, 9)
        XCTAssertEqual(ReminderPriority.none.ekValue, 0)
        XCTAssertEqual(ReminderPriority(ekValue: 2), .high)
        XCTAssertEqual(ReminderPriority(ekValue: 7), .low)
        XCTAssertEqual(ReminderPriority(ekValue: 0), ReminderPriority.none)
    }
}
