import XCTest
@testable import MailModule

final class MailScriptsTests: XCTestCase {
    func testUnreadScriptStructure() {
        let script = MailScripts.unread(account: nil, limit: 20)
        XCTAssertTrue(script.contains("read status is false"))
        XCTAssertTrue(script.contains("is greater than or equal to 20"))
        XCTAssertTrue(script.contains("character id 31"))
        XCTAssertTrue(script.contains("character id 30"))
        XCTAssertFalse(script.contains("acctName is not")) // no account filter when account is nil
    }

    func testUnreadScriptEscapesAccountFilter() {
        let script = MailScripts.unread(account: #"Wo"rk"#, limit: 5)
        XCTAssertTrue(script.contains(#"Wo\"rk"#))
    }

    func testSearchScriptContainsEscapedQueryInBothClauses() {
        let script = MailScripts.search(query: #"inv"oice"#, limit: 10)
        XCTAssertEqual(script.components(separatedBy: #"inv\"oice"#).count - 1, 2) // subject + sender
    }

    func testReadScriptHasSentinelAndBody() {
        let script = MailScripts.read(id: "<m1@x>")
        XCTAssertTrue(script.contains("NOTFOUND"))
        XCTAssertTrue(script.contains(#"message id is "<m1@x>""#))
        XCTAssertTrue(script.contains("content of m"))
    }

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

    func testAccountsScriptEnumeratesAccountNames() {
        let script = MailScripts.accounts()
        XCTAssertTrue(script.contains("repeat with a in accounts"))
        XCTAssertTrue(script.contains("name of a"))
        XCTAssertTrue(script.contains("character id 30"))
    }

    func testArchiveScriptSentinels() {
        let script = MailScripts.archive(id: "<m1@x>")
        XCTAssertTrue(script.contains("NOTFOUND"))
        XCTAssertTrue(script.contains("NOARCHIVE:"))
        XCTAssertTrue(script.contains(#"mailbox "Archive""#))
    }
}
