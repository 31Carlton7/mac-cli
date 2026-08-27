import XCTest
@testable import MailModule

final class MailScriptsTests: XCTestCase {
    /// One instance of every builder, for the invariants that must hold across all of them.
    static let allReadScripts: [(String, String)] = [
        ("accounts", MailScripts.accounts()),
        ("accountInboxes", MailScripts.accountInboxes()),
        ("window", MailScripts.window(account: "Work", scan: 30)),
        ("find", MailScripts.find(account: "Work", id: "<m1@x>", scan: 30)),
        ("markRead", MailScripts.markRead(account: "Work", id: "<m1@x>", scan: 30)),
        ("archive", MailScripts.archive(account: "Work", id: "<m1@x>", scan: 30)),
    ]

    // MARK: - Invariants across every builder

    /// The bug this module was rewritten for: `whose` on a 97k-message inbox
    /// pins Mail at 98% CPU for minutes and never returns.
    func testNoGeneratedScriptUsesWhoseFiltering() {
        let draft = MailDraft(to: "a@b.com", cc: nil, subject: "s", body: "b")
        let every = Self.allReadScripts + [
            ("composeDraft", MailScripts.compose(draft, send: false)),
            ("composeSend", MailScripts.compose(draft, send: true)),
        ]
        for (name, script) in every {
            XCTAssertFalse(script.contains("whose"), "\(name) still uses a `whose` filter")
        }
    }

    func testEveryReadScriptBoundsTheAppleEventTimeout() {
        for (name, script) in Self.allReadScripts {
            XCTAssertTrue(script.contains("with timeout of 600 seconds"), "\(name) has no timeout")
            XCTAssertTrue(script.contains("end timeout"), "\(name) has an unterminated timeout")
        }
    }

    /// `mailbox "Inbox" of account N` is case-sensitive and fails outright on
    /// accounts whose inbox is named `INBOX`; AppleScript's `is` is not.
    func testMailboxScriptsFindTheInboxCaseInsensitively() {
        for (name, script) in Self.allReadScripts where name != "accounts" {
            XCTAssertTrue(script.contains(#"(name of m) is "Inbox""#), "\(name) does not scan for the inbox")
            XCTAssertFalse(script.contains(#"mailbox "Inbox""#), "\(name) uses a case-sensitive inbox lookup")
        }
    }

    // MARK: - accounts / accountInboxes

    func testAccountsScriptEnumeratesAccountNames() {
        let script = MailScripts.accounts()
        XCTAssertTrue(script.contains("repeat with a in accounts"))
        XCTAssertTrue(script.contains("name of a"))
        XCTAssertTrue(script.contains("character id 30"))
    }

    func testAccountInboxesCountsWithoutTouchingMessageProperties() {
        let script = MailScripts.accountInboxes()
        XCTAssertTrue(script.contains("count of messages of mb"))
        XCTAssertTrue(script.contains("character id 31"))
        XCTAssertTrue(script.contains("character id 30"))
        // The cost proxy must stay free: no per-message property reads.
        for property in ["message id of", "subject of messages", "date received of", "read status of"] {
            XCTAssertFalse(script.contains(property), "accountInboxes touches \(property)")
        }
    }

    // MARK: - window

    func testWindowBulkFetchesFivePropertiesOverTheClampedRange() {
        let script = MailScripts.window(account: "Work", scan: 30)
        for property in ["message id", "subject", "sender", "date received", "read status"] {
            XCTAssertTrue(script.contains("\(property) of messages 1 thru k of mb"),
                          "window does not bulk-fetch \(property)")
        }
        XCTAssertTrue(script.contains("set k to 30"))
        XCTAssertTrue(script.contains("if k > total then set k to total"))
        XCTAssertTrue(script.contains("repeat with i from 1 to k"))
    }

    func testWindowEscapesTheAccountName() {
        let script = MailScripts.window(account: #"Wo"rk"#, scan: 30)
        XCTAssertTrue(script.contains(#"(name of a) is "Wo\"rk""#))
    }

    // MARK: - find

    func testFindCarriesTheNotFoundSentinelAndTheBodyField() {
        let script = MailScripts.find(account: "Work", id: "<m1@x>", scan: 30)
        XCTAssertTrue(script.contains("NOTFOUND"))
        XCTAssertTrue(script.contains("content of message"))
        XCTAssertTrue(script.contains("message id of messages 1 thru k of mb"))
    }

    func testFindEscapesBothAccountAndID() {
        let script = MailScripts.find(account: #"Wo"rk"#, id: #"<m"1@x>"#, scan: 30)
        XCTAssertTrue(script.contains(#"Wo\"rk"#))
        XCTAssertTrue(script.contains(#"<m\"1@x>"#))
    }

    // MARK: - markRead

    func testMarkReadSetsReadStatusAndCarriesTheSentinel() {
        let script = MailScripts.markRead(account: "Work", id: "<m1@x>", scan: 30)
        XCTAssertTrue(script.contains("NOTFOUND"))
        XCTAssertTrue(script.contains("set read status of message"))
        XCTAssertTrue(script.contains(#"return "ok""#))
    }

    func testMarkReadEscapesBothAccountAndID() {
        let script = MailScripts.markRead(account: #"Wo"rk"#, id: #"<m"1@x>"#, scan: 30)
        XCTAssertTrue(script.contains(#"Wo\"rk"#))
        XCTAssertTrue(script.contains(#"<m\"1@x>"#))
    }

    // MARK: - archive

    func testArchiveScriptSentinels() {
        let script = MailScripts.archive(account: "Work", id: "<m1@x>", scan: 30)
        XCTAssertTrue(script.contains("NOTFOUND"))
        XCTAssertTrue(script.contains("NOARCHIVE:"))
        XCTAssertTrue(script.contains(#"is "Archive""#))
        XCTAssertTrue(script.contains("to archiveBox"))
    }

    func testArchiveEscapesBothAccountAndID() {
        let script = MailScripts.archive(account: #"Wo"rk"#, id: #"<m"1@x>"#, scan: 30)
        XCTAssertTrue(script.contains(#"Wo\"rk"#))
        XCTAssertTrue(script.contains(#"<m\"1@x>"#))
    }

    // MARK: - compose (unchanged)

    func testComposeScriptEscapesAndRoutes() {
        let draft = MailDraft(to: "a@b.com", cc: "c@d.com",
                              subject: #"He said "hi""#, body: "line1\nline2")
        let asDraft = MailScripts.compose(draft, send: false)
        XCTAssertTrue(asDraft.contains(#"He said \"hi\""#))
        XCTAssertTrue(asDraft.contains(#"line1\nline2"#))
        XCTAssertTrue(asDraft.contains("visible:true"))
        XCTAssertTrue(asDraft.contains("cc recipient"))
        XCTAssertFalse(asDraft.contains("send msg"))
        let asSend = MailScripts.compose(draft, send: true)
        XCTAssertTrue(asSend.contains("send msg"))
        XCTAssertTrue(asSend.contains("visible:false"))
    }
}
