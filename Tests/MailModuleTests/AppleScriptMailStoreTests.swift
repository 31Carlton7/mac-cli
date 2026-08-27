import XCTest
import Core
@testable import MailModule

final class AppleScriptMailStoreTests: XCTestCase {
    let fs = AppleScript.fieldSep
    let rs = AppleScript.recordSep

    // MARK: - window rows (6 fields)

    func testParsesWellFormedWindowRecords() {
        let output = ["<m1>", "Subject One", "a@b.com", "2026-08-27T10:00:00", "0", "Work"].joined(separator: fs)
            + rs + ["<m2>", "Subject Two", "c@d.com", "2026-08-27T11:00:00", "1", "Personal"].joined(separator: fs)
        let items = AppleScriptMailStore.emails(from: output)
        XCTAssertEqual(items.map(\.id), ["<m1>", "<m2>"])
        XCTAssertEqual(items[0].isRead, false)
        XCTAssertEqual(items[1].isRead, true)
        XCTAssertEqual(items[0].account, "Work")
        XCTAssertNil(items[0].body)
    }

    // MARK: - find row (7 fields)

    func testBodyFieldOnlyWhenRequestedAndPresent() {
        let withBody = ["<m1>", "s", "f", "2026-08-27T10:00:00", "0", "Work", "the body"].joined(separator: fs)
        XCTAssertEqual(AppleScriptMailStore.emails(from: withBody, bodyField: true).first?.body, "the body")
        XCTAssertNil(AppleScriptMailStore.emails(from: withBody, bodyField: false).first?.body)
    }

    func testFindRowKeepsAllSixEnvelopeFieldsAlongsideTheBody() {
        let row = ["<m1>", "Subject", "a@b.com", "2026-08-27T10:00:00", "1", "Work", "line one"].joined(separator: fs)
        let item = AppleScriptMailStore.emails(from: row, bodyField: true).first
        XCTAssertEqual(item?.subject, "Subject")
        XCTAssertEqual(item?.from, "a@b.com")
        XCTAssertEqual(item?.isRead, true)
        XCTAssertEqual(item?.account, "Work")
        XCTAssertEqual(item?.body, "line one")
    }

    func testMalformedRecordsAreSkipped() {
        let output = ["<m1>", "s", "f", "2026-08-27T10:00:00", "0", "Work"].joined(separator: fs)
            + rs + "garbage-row"
        let items = AppleScriptMailStore.emails(from: output)
        XCTAssertEqual(items.map(\.id), ["<m1>"])
    }

    func testEmptyOutputYieldsNoItems() {
        XCTAssertTrue(AppleScriptMailStore.emails(from: "").isEmpty)
    }

    // MARK: - accountInboxes rows (2 fields)

    func testParsesAccountInboxRecords() {
        let output = ["Work", "9521"].joined(separator: fs)
            + rs + ["Personal", "1733"].joined(separator: fs)
        XCTAssertEqual(AppleScriptMailStore.accountInfos(from: output),
                       [MailAccountInfo(name: "Work", inboxCount: 9521),
                        MailAccountInfo(name: "Personal", inboxCount: 1733)])
    }

    /// -1 is the script's "this account has no inbox mailbox" marker; it must
    /// survive parsing so the actions layer can drop it.
    func testAccountWithoutAnInboxKeepsItsNegativeMarker() {
        let output = ["Notes", "-1"].joined(separator: fs)
        XCTAssertEqual(AppleScriptMailStore.accountInfos(from: output),
                       [MailAccountInfo(name: "Notes", inboxCount: -1)])
    }

    func testMalformedAccountInboxRecordsAreSkipped() {
        let output = ["Work", "9521"].joined(separator: fs)
            + rs + ["Broken", "not-a-number"].joined(separator: fs)
            + rs + "no-separator"
        XCTAssertEqual(AppleScriptMailStore.accountInfos(from: output),
                       [MailAccountInfo(name: "Work", inboxCount: 9521)])
    }

    func testEmptyAccountInboxOutputYieldsNoInfos() {
        XCTAssertTrue(AppleScriptMailStore.accountInfos(from: "").isEmpty)
    }
}
