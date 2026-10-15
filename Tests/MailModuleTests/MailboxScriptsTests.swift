import XCTest
import Core
@testable import MailModule

final class MailboxScriptsTests: XCTestCase {
    static let all: [(String, String)] = [
        ("mailboxTree", MailScripts.mailboxTree(account: "Work")),
        ("createMailbox", MailScripts.createMailbox(account: "Work", parent: "Projects", path: "Projects/2026")),
        ("renameMailbox", MailScripts.renameMailbox(account: "Work", path: "Projects/2026",
                                                    newName: "2027", newPath: "Projects/2027")),
        ("deleteMailbox", MailScripts.deleteMailbox(account: "Work", path: "Projects/2026")),
    ]

    // MARK: - Invariants

    func testNoMailboxScriptUsesWhose() {
        for (name, script) in Self.all {
            XCTAssertFalse(script.contains("whose"), "\(name) uses a `whose` filter")
        }
    }

    func testEveryMailboxScriptBoundsTheAppleEventTimeout() {
        for (name, script) in Self.all {
            XCTAssertTrue(script.contains("with timeout of 600 seconds"), "\(name) has no timeout")
            XCTAssertTrue(script.contains("end timeout"), "\(name) has an unterminated timeout")
        }
    }

    /// `mailbox "X" of account` is case-sensitive and misses `INBOX`-style names,
    /// so mailboxes are always found by walking `mailboxes of` the account.
    func testMailboxesAreFoundByWalkingNotByNamedLookup() {
        for (name, script) in Self.all {
            XCTAssertTrue(script.contains("repeat with m in (mailboxes of acct)"), "\(name) does not walk the account")
            XCTAssertTrue(script.contains("my walkMailboxes(acct)"), "\(name) does not call the walker")
            XCTAssertFalse(script.contains(#"mailbox ""#), "\(name) uses a named mailbox lookup")
            XCTAssertTrue(script.contains(#"return "NOACCOUNT""#), "\(name) has no unknown-account sentinel")
        }
    }

    func testMutationsMatchTheResolvedPathCaseSensitively() {
        for (name, script) in Self.all where name != "mailboxTree" {
            XCTAssertTrue(script.contains("considering case"), "\(name) matches paths case-insensitively")
            XCTAssertTrue(script.contains("my hasPath("), "\(name) does not check the path after the change")
        }
    }

    func testTheTreeIsReadOnly() {
        let script = MailScripts.mailboxTree(account: "Work")
        for verb in ["make new", "set name of", "delete "] {
            XCTAssertFalse(script.contains(verb), "mailboxTree contains \(verb)")
        }
        XCTAssertTrue(script.contains("count of messages of (item i of boxes)"))
    }

    // MARK: - Sentinels and verbs

    func testCreateMakesTheFullPathAfterCheckingParentAndCollision() {
        let script = MailScripts.createMailbox(account: "Work", parent: "Projects", path: "Projects/2026")
        XCTAssertTrue(script.contains(#"tell acct to make new mailbox with properties {name:"Projects/2026"}"#))
        for sentinel in ["NOPARENT", "EXISTS", "UNVERIFIED"] {
            XCTAssertTrue(script.contains(sentinel), "create lacks \(sentinel)")
        }
        let topLevel = MailScripts.createMailbox(account: "Work", parent: nil, path: "Receipts")
        XCTAssertFalse(topLevel.contains("NOPARENT"))
    }

    func testRenameWritesTheNameInTheFormMailReports() {
        let script = MailScripts.renameMailbox(account: "Work", path: "Projects/2026",
                                               newName: "2027", newPath: "Projects/2027")
        XCTAssertTrue(script.contains(#"set name of mb to "Projects/2027""#))
        XCTAssertTrue(script.contains(#"set name of mb to "2027""#))
        for sentinel in ["NOMAILBOX", "EXISTS", "UNVERIFIED"] {
            XCTAssertTrue(script.contains(sentinel), "rename lacks \(sentinel)")
        }
    }

    func testDeleteRechecksChildrenAndMessagesBeforeDeleting() {
        let script = MailScripts.deleteMailbox(account: "Work", path: "Projects/2026")
        let children = script.range(of: "HASCHILDREN:")!.lowerBound
        let messages = script.range(of: "NOTEMPTY:")!.lowerBound
        let delete = script.range(of: "delete mb")!.lowerBound
        XCTAssertLessThan(children, delete)
        XCTAssertLessThan(messages, delete)
        XCTAssertTrue(script.contains(#"starts with "Projects/2026/""#))
        XCTAssertTrue(script.contains("NOMAILBOX"))
        XCTAssertTrue(script.contains("UNVERIFIED"))
    }

    // MARK: - Escaping hostile names

    func testHostileValuesAreEscapedEverywhere() {
        let account = #"Wo"rk\"#
        let path = #"Pro"jects\/2026 ✓ "end"#
        let scripts = [
            MailScripts.mailboxTree(account: account),
            MailScripts.createMailbox(account: account, parent: path, path: path + "/Ünïcödé \"x\""),
            MailScripts.renameMailbox(account: account, path: path, newName: #"N"ew\"#, newPath: #"Pro/N"ew\"#),
            MailScripts.deleteMailbox(account: account, path: path),
        ]
        for script in scripts {
            XCTAssertTrue(script.contains(#"(name of a) is "Wo\"rk\\""#))
            XCTAssertFalse(script.contains(#""Wo"rk"#), "raw account quote leaked")
            XCTAssertFalse(script.contains(#""Pro"jects"#), "raw path quote leaked")
        }
        XCTAssertTrue(scripts[1].contains(#"Pro\"jects\\/2026 ✓ \"end/Ünïcödé \"x\""#))
        XCTAssertTrue(scripts[2].contains(#"set name of mb to "N\"ew\\""#))
        XCTAssertTrue(scripts[2].contains(#"set name of mb to "Pro/N\"ew\\""#))
        XCTAssertTrue(scripts[3].contains(#""Pro\"jects\\/2026 ✓ \"end""#))
    }

    func testNewlinesInValuesCannotBreakOutOfTheLiteral() {
        let script = MailScripts.deleteMailbox(account: "Work\nend tell", path: "A\"\ndo shell script \"x")
        XCTAssertFalse(script.contains("\ndo shell script"))
        XCTAssertFalse(script.contains("Work\nend tell"))
        XCTAssertTrue(script.contains(#"A\"\ndo shell script \"x"#))
    }

    // MARK: - Store parsing

    func testParsesEverySentinel() throws {
        let cases: [(String, MailboxScriptResult)] = [
            ("ok", .ok), ("NOACCOUNT", .noAccount), ("NOMAILBOX", .noMailbox),
            ("NOPARENT", .noParent), ("EXISTS", .exists), ("UNVERIFIED", .unverified),
            ("HASCHILDREN:3", .hasChildren(3)), ("NOTEMPTY:42", .notEmpty(42)),
        ]
        for (output, expected) in cases {
            XCTAssertEqual(try AppleScriptMailStore.mailboxResult(from: output), expected, output)
        }
    }

    func testUnrecognisedResponsesAreErrorsNeverSuccess() {
        for output in ["", "OK", "ok ", "true", "NOTEMPTY:", "NOTEMPTY:x", "HASCHILDREN:1.5", "missing value"] {
            XCTAssertThrowsError(try AppleScriptMailStore.mailboxResult(from: output), "accepted '\(output)'")
        }
    }

    func testParsesTheTree() throws {
        let fs = AppleScript.fieldSep, rs = AppleScript.recordSep
        let output = ["Work", "INBOX\(fs)120", "Projects\(fs)0", "Projects/2026\(fs)-1"].joined(separator: rs)
        XCTAssertEqual(try AppleScriptMailStore.mailboxTree(from: output), MailboxTree(account: "Work", mailboxes: [
            MailboxEntry(path: "INBOX", messageCount: 120),
            MailboxEntry(path: "Projects", messageCount: 0),
            MailboxEntry(path: "Projects/2026", messageCount: -1),
        ]))
        XCTAssertEqual(try AppleScriptMailStore.mailboxTree(from: "Work"), MailboxTree(account: "Work", mailboxes: []))
        XCTAssertNil(try AppleScriptMailStore.mailboxTree(from: "NOACCOUNT"))
    }

    func testAMalformedTreeRowFailsTheWholeRead() {
        let fs = AppleScript.fieldSep, rs = AppleScript.recordSep
        for output in ["", "Work\(rs)INBOX", "Work\(rs)INBOX\(fs)lots", "Work\(fs)x\(rs)INBOX\(fs)1",
                       "Work\(rs)\(fs)3", "Work\(rs)A\(fs)1\(fs)extra"] {
            XCTAssertThrowsError(try AppleScriptMailStore.mailboxTree(from: output), "accepted \(output.debugDescription)")
        }
    }
}
