import XCTest
@testable import CalendarModule

final class CalendarCommandParsingTests: XCTestCase {
    func testListParses() throws {
        _ = try CalendarCommand.parseAsRoot(["list", "--from", "today", "--to", "+7d", "--json"])
    }

    func testAddRequiresAt() {
        XCTAssertThrowsError(try CalendarCommand.parseAsRoot(["add", "Dentist"]))
        XCTAssertNoThrow(try CalendarCommand.parseAsRoot(["add", "Dentist", "--at", "tomorrow 2pm"]))
    }

    func testDeleteRequiresID() {
        XCTAssertThrowsError(try CalendarCommand.parseAsRoot(["delete"]))
        XCTAssertNoThrow(try CalendarCommand.parseAsRoot(["delete", "some-id"]))
    }
}
