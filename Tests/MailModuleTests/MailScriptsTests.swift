import XCTest
import Core
@testable import MailModule

final class MailScriptsTests: XCTestCase {
    /// One instance of every builder, for the invariants that must hold across all of them.
    static let allReadScripts: [(String, String)] = [
        ("accounts", MailScripts.accounts()),
        ("accountDirectory", MailScripts.accountDirectory()),
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
            ("body", MailScripts.body(rowID: 101, accountID: "GM", mailbox: "[Gmail]/All Mail")),
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
        for (name, script) in Self.allReadScripts where !name.hasPrefix("account") || name == "accountInboxes" {
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

    func testAccountDirectoryBulkFetchesIDNameAndEnabledInOneScript() {
        let script = MailScripts.accountDirectory()
        XCTAssertTrue(script.contains("set ids to id of every account"))
        XCTAssertTrue(script.contains("set names to name of every account"))
        XCTAssertTrue(script.contains("set flags to enabled of every account"))
        XCTAssertFalse(script.contains("mailboxes of"), "the directory must not touch mailboxes")
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

    // MARK: - body

    /// `message id 101` parses as the RFC `message id` property followed by a
    /// stray number, so the by-id reference spells the class by its code.
    func testBodyReferencesTheMessageByNumericIDInItsOwnMailbox() {
        let script = MailScripts.body(rowID: 101, accountID: "GM", mailbox: "[Gmail]/All Mail")
        XCTAssertTrue(script.contains(#"«class mssg» id 101 of mailbox "[Gmail]/All Mail" of account id "GM""#))
        XCTAssertTrue(script.contains("on error number -1728"), "only a missing object is NOTFOUND")
        XCTAssertTrue(script.contains("NOTFOUND"))
        XCTAssertTrue(script.contains(#"return "BODY:" & bodyVal"#))
        XCTAssertTrue(script.contains("with timeout of 600 seconds"))
        XCTAssertFalse(script.contains("messages 1 thru"), "no window")
    }

    func testBodyEscapesMailboxAndAccount() {
        let script = MailScripts.body(rowID: 1, accountID: #"G"M"#, mailbox: #"a"b"#)
        XCTAssertTrue(script.contains(#"mailbox "a\"b" of account id "G\"M""#))
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

    func testComposeWithHTMLSetsHTMLBeforeAttachingFiles() throws {
        let draft = MailDraft(to: "a@b.com", cc: nil, subject: "s", body: "ignored",
                              html: "<h1>Hi</h1>", attachments: ["/tmp/a.pdf", "/tmp/b.txt"])
        let script = MailScripts.compose(draft, send: false)
        XCTAssertFalse(script.contains("content:\""), "HTML messages must not also set plain content")
        XCTAssertFalse(script.contains("ignored"))
        let html = try XCTUnwrap(script.range(of: "set html content of msg to \"<h1>Hi</h1>\""))
        let firstAttachment = try XCTUnwrap(script.range(of: #"POSIX file "/tmp/a.pdf""#))
        XCTAssertTrue(script.contains(#"POSIX file "/tmp/b.txt""#))
        XCTAssertLessThan(html.lowerBound, firstAttachment.lowerBound,
                          "html content replaces the body, so attaching first loses the files")
        XCTAssertFalse(script.contains("delay"), "a draft is shown, not sent, so it need not wait")
    }

    func testSendWithAttachmentsWaitsBeforeSending() throws {
        let draft = MailDraft(to: "a@b.com", cc: nil, subject: "s", body: "b", attachments: ["/tmp/a.pdf"])
        let script = MailScripts.compose(draft, send: true)
        XCTAssertTrue(script.contains(#"content:"b""#))
        let delay = try XCTUnwrap(script.range(of: "delay 1"))
        let send = try XCTUnwrap(script.range(of: "send msg"))
        XCTAssertLessThan(delay.lowerBound, send.lowerBound)
        XCTAssertFalse(MailScripts.compose(MailDraft(to: "a@b.com", cc: nil, subject: "s", body: "b"),
                                           send: true).contains("delay"))
    }

    func testComposeKeepsQuotedDisplayNamesWhole() throws {
        let draft = MailDraft(to: #""Doe, John" <j@x.com>, Ann Lee <a@b.com>"#, cc: "e@f.com (Eve)",
                              subject: "s", body: "b")
        for send in [false, true] {
            let script = MailScripts.compose(draft, send: send)
            XCTAssertTrue(script.contains(#"make new to recipient with properties {name:"Doe, John", address:"j@x.com"}"#))
            XCTAssertTrue(script.contains(#"make new to recipient with properties {name:"Ann Lee", address:"a@b.com"}"#))
            XCTAssertTrue(script.contains(#"make new cc recipient with properties {name:"Eve", address:"e@f.com"}"#))
            XCTAssertEqual(script.components(separatedBy: "make new to recipient").count - 1, 2)
            XCTAssertFalse(script.contains(#"address:""Doe""#))
        }
        // Mail reports addresses alone, so the read-back compares addresses.
        XCTAssertTrue(MailScripts.compose(draft, send: true)
            .contains(#"if toList is not {"j@x.com", "a@b.com"} or ccList is not {"e@f.com"} then"#))
    }

    func testRecipientListsSplitOnlyBetweenAddresses() {
        func parsed(_ field: String) -> [String] {
            MailRecipient.list(field).map { ($0.name.map { "\($0) | " } ?? "") + $0.address }
        }
        XCTAssertEqual(parsed("a@b.com,c@d.com"), ["a@b.com", "c@d.com"])
        XCTAssertEqual(parsed(" , a@b.com ,, "), ["a@b.com"], "blank parts are skipped")
        XCTAssertEqual(parsed(#""Doe, John" <j@x.com>"#), ["Doe, John | j@x.com"])
        XCTAssertEqual(parsed(#""Say \"hi\", ok" <j@x.com>"#), [#"Say "hi", ok | j@x.com"#])
        XCTAssertEqual(parsed("Ann (work, main) <a@b.com>"), ["Ann | a@b.com"], "a comment's comma does not split")
        XCTAssertEqual(parsed("<a@b.com>"), ["a@b.com"])
        XCTAssertEqual(parsed("a@b.com (Ann Lee)"), ["Ann Lee | a@b.com"])
        XCTAssertEqual(parsed("Ann\nBcc: x@y.com <a@b.com>"), ["Ann Bcc: x@y.com | a@b.com"],
                       "a newline in a name cannot start a header")
        XCTAssertEqual(parsed(#""a@b.com>, <evil@x.com" <real@y.com>"#), ["a@b.com>, <evil@x.com | real@y.com"],
                       "brackets inside quotes are part of the name")
    }

    func testUnreadableRecipientsFailValidation() {
        for field in [#""Doe, John <j@x.com>"#, "Ann <a@b.com", "<a@b.com> <c@d.com>", #""a"@b.com"#,
                      "Doe", "a@b", "a b@c.com", "Ann (unclosed <a@b.com>", "a@b.com\u{0}"] {
            let recipients = MailRecipient.list(field)
            XCTAssertTrue(recipients.contains { !$0.hasValidAddress }, "\(field) -> \(recipients)")
        }
        XCTAssertTrue(MailRecipient.list(#""Doe, John" <j@x.com>, a@b.co"#).allSatisfy(\.hasValidAddress))
    }

    func testSendChecksTheRecipientsAndSendsOnlyOnAMatch() throws {
        let draft = MailDraft(to: "Ann <a@b.com>, c@d.com", cc: "e@f.com", subject: "s", body: "b")
        let script = MailScripts.compose(draft, send: true)
        XCTAssertTrue(script.contains(#"make new to recipient with properties {name:"Ann", address:"a@b.com"}"#))
        XCTAssertTrue(script.contains(#"make new to recipient with properties {address:"c@d.com"}"#))
        let check = try XCTUnwrap(script.range(of: #"if toList is not {"a@b.com", "c@d.com"} or ccList is not {"e@f.com"} then"#))
        let send = try XCTUnwrap(script.range(of: #"if (send msg) then return "sent""#))
        XCTAssertLessThan(check.lowerBound, send.lowerBound)
        XCTAssertTrue(script.hasSuffix(#"return "failed""#))
        XCTAssertFalse(script.contains(#"return "ok""#))
        XCTAssertTrue(MailScripts.compose(MailDraft(to: "a@b.com", cc: nil, subject: "s", body: "b"), send: true)
            .contains("or ccList is not {} then"))
    }

    func testSendFailsUnlessMailSaysSent() {
        XCTAssertNoThrow(try AppleScriptMailStore.sent("sent"))
        for out in ["ok", "failed", "", "UNSENT\u{1F}x@y.com\u{1F}"] {
            XCTAssertThrowsError(try AppleScriptMailStore.sent(out), out) { error in
                XCTAssertEqual((error as? MacError)?.code, .badInput)
                XCTAssertTrue((error as? MacError)?.message.contains("open in Mail as a draft") == true)
            }
        }
        XCTAssertThrowsError(try AppleScriptMailStore.sent("UNSENT\u{1F}x@y.com\u{1F}z@y.com")) { error in
            XCTAssertTrue((error as? MacError)?.message.contains("To x@y.com and Cc z@y.com") == true)
        }
    }

    func testComposeEscapesHostileAttachmentPathAndHTML() {
        let draft = MailDraft(to: "a@b.com", cc: nil, subject: "s", body: "",
                              html: "<a href=\"x\">\\</a>\n»",
                              attachments: [#"/tmp/we"ird\name.txt"#])
        let script = MailScripts.compose(draft, send: true)
        XCTAssertTrue(script.contains(#"set html content of msg to "<a href=\"x\">\\</a>\n»""#))
        XCTAssertTrue(script.contains(#"POSIX file "/tmp/we\"ird\\name.txt""#))
    }

    /// Runs each hostile value through the real AppleScript parser as a string
    /// literal and checks it comes back unchanged. No application is targeted.
    func testEscapedValuesRoundTripThroughAppleScript() throws {
        let hostile = [
            #"He said "hi" and left"#,
            #"C:\path\to\file\"#,
            "line one\nline two\r\nline three",
            "chevrons «data utxt» and » alone",
            "unicode ✓ é 日本 👋🏽",
            #"" & (do shell script "echo pwned") & ""#,
            "end tell\nreturn \"injected\"",
        ]
        for value in hostile {
            let source = "return \"\(AppleScript.escape(value))\""
            let script = try XCTUnwrap(NSAppleScript(source: source))
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            XCTAssertNil(error, "\(value) did not compile: \(String(describing: error))")
            XCTAssertEqual(result.stringValue, value)
        }
    }
}
