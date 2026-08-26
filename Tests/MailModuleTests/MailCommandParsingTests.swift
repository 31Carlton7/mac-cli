import XCTest
@testable import MailModule

final class MailCommandParsingTests: XCTestCase {
    func testUnreadParses() throws {
        _ = try MailCommand.parseAsRoot(["unread", "--account", "Work", "--limit", "10", "--json"])
    }

    func testAccountsParses() {
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["accounts", "--json"]))
    }

    func testDraftRequiresTo() {
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["draft", "--subject", "hi"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["draft", "--to", "a@b.com", "--subject", "hi"]))
    }

    func testMarkReadRequiresID() {
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["mark-read"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["mark-read", "<m1@x>"]))
    }
}
