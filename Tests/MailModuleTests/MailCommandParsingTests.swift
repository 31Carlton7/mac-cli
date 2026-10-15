import XCTest
@testable import MailModule

final class MailCommandParsingTests: XCTestCase {
    func testUnreadParses() throws {
        _ = try MailCommand.parseAsRoot(["unread", "--account", "Work", "--limit", "10", "--json"])
    }

    /// Reads come from Mail's Envelope Index, so the summary must not say
    /// everything goes through Mail.app.
    func testTheAbstractDoesNotClaimEverythingGoesThroughMailApp() {
        XCTAssertFalse(MailCommand.configuration.abstract.contains("Mail.app"))
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

    func testActionsTakeSeveralIDsAndTheTargetFlags() throws {
        let parsed = try MailCommand.parseAsRoot(["archive", "a@x", "<b@x>", "--account", "Work",
                                                  "--mailbox", "Inbox", "--dry-run", "--json"])
        let archive = try XCTUnwrap(parsed as? MailCommand.Archive)
        XCTAssertEqual(archive.target.ids, ["a@x", "<b@x>"])
        XCTAssertEqual(archive.target.account, "Work")
        XCTAssertEqual(archive.target.mailbox, "Inbox")
        XCTAssertTrue(archive.target.dryRun)
        XCTAssertNil(archive.scan)
    }

    func testNewActionsParse() throws {
        for verb in ["mark-unread", "flag", "unflag", "delete"] {
            XCTAssertNoThrow(try MailCommand.parseAsRoot([verb, "a@x", "b@x", "--dry-run", "--json"]), verb)
            XCTAssertThrowsError(try MailCommand.parseAsRoot([verb]), "\(verb) needs an id")
            XCTAssertThrowsError(try MailCommand.parseAsRoot([verb, "a@x", "--scan", "50"]),
                                 "\(verb) has no window path, so no --scan")
        }
        let move = try XCTUnwrap(try MailCommand.parseAsRoot(["move", "a@x", "--to", "Archive"]) as? MailCommand.Move)
        XCTAssertEqual(move.to, "Archive")
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["move", "a@x"]), "move needs --to")
    }
}
