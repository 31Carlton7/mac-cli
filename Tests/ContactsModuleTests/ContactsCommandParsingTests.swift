import XCTest
@testable import ContactsModule

final class ContactsCommandParsingTests: XCTestCase {
    func testFindRequiresQuery() {
        XCTAssertThrowsError(try ContactsCommand.parseAsRoot(["find"]))
        XCTAssertNoThrow(try ContactsCommand.parseAsRoot(["find", "Sarah", "--json"]))
    }

    func testAddRequiresName() {
        XCTAssertThrowsError(try ContactsCommand.parseAsRoot(["add", "--email", "x@example.com"]))
        XCTAssertNoThrow(try ContactsCommand.parseAsRoot(["add", "--name", "Sarah Chen"]))
    }
}
