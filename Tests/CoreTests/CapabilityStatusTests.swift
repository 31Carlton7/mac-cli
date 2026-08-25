import XCTest
@testable import Core

final class CapabilityStatusTests: XCTestCase {
    func testGrantedHasNoFix() {
        let s = CapabilityStatus(capability: "calendar", status: .granted, pane: "Calendars")
        XCTAssertNil(s.fix)
        XCTAssertEqual(s.humanLine, "calendar: granted")
    }

    func testDeniedPointsAtSystemSettings() {
        let s = CapabilityStatus(capability: "contacts", status: .denied, pane: "Contacts")
        XCTAssertEqual(s.fix, "Enable full access in System Settings > Privacy & Security > Contacts for your terminal app.")
        XCTAssertTrue(s.humanLine.hasPrefix("contacts: denied  — "))
    }

    func testNotRequestedSaysHowToTrigger() {
        let s = CapabilityStatus(capability: "reminders", status: .notRequested, pane: "Reminders")
        XCTAssertEqual(s.fix, "Run any `mac reminders` command to trigger the macOS permission prompt.")
    }

    func testJSONShape() throws {
        let s = CapabilityStatus(capability: "calendar", status: .granted, pane: "Calendars")
        let json = String(data: try Output.encoder.encode(s), encoding: .utf8)!
        XCTAssertEqual(json, #"{"capability":"calendar","status":"granted"}"#)
    }
}
