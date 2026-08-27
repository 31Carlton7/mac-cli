import XCTest
@testable import MailModule

final class MailCommandParsingTests: XCTestCase {
    func testUnreadParses() throws {
        _ = try MailCommand.parseAsRoot(["unread", "--account", "Work", "--limit", "10", "--json"])
    }

    func testReadPathsAcceptScan() {
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["unread", "--scan", "100"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["search", "invoice", "--scan", "100"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["read", "<m1@x>", "--scan", "100"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["mark-read", "<m1@x>", "--scan", "100"]))
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["archive", "<m1@x>", "--scan", "100"]))
    }

    func testAccountsParses() {
        XCTAssertNoThrow(try MailCommand.parseAsRoot(["accounts", "--json"]))
    }

    // MARK: - `accounts --json` output contract

    func testAccountsJSONShapeIsBareStringArray() {
        XCTAssertEqual(MailCommand.Accounts.accountsJSON(["Work", "Personal"]),
                       #"["Work","Personal"]"#)
    }

    func testAccountsJSONPreservesStoreOrderAndEscapes() {
        // Mail's own order is the contract — no sorting — and a name containing a
        // quote must not corrupt the array.
        XCTAssertEqual(MailCommand.Accounts.accountsJSON([]), "[]")
        XCTAssertEqual(MailCommand.Accounts.accountsJSON([#"Wo"rk"#]), #"["Wo\"rk"]"#)
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
