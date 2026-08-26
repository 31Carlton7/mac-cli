import XCTest
import Core
@testable import MailModule

final class AppleScriptMailStoreTests: XCTestCase {
    func testParsesWellFormedRecords() {
        let fs = AppleScript.fieldSep, rs = AppleScript.recordSep
        let output = ["<m1>", "Subject One", "a@b.com", "2026-08-27T10:00:00", "0", "Work"].joined(separator: fs)
            + rs + ["<m2>", "Subject Two", "c@d.com", "2026-08-27T11:00:00", "1", "Personal"].joined(separator: fs)
        let items = AppleScriptMailStore.emails(from: output)
        XCTAssertEqual(items.map(\.id), ["<m1>", "<m2>"])
        XCTAssertEqual(items[0].isRead, false)
        XCTAssertEqual(items[1].isRead, true)
        XCTAssertEqual(items[0].account, "Work")
        XCTAssertNil(items[0].body)
    }

    func testBodyFieldOnlyWhenRequestedAndPresent() {
        let fs = AppleScript.fieldSep
        let withBody = ["<m1>", "s", "f", "2026-08-27T10:00:00", "0", "Work", "the body"].joined(separator: fs)
        XCTAssertEqual(AppleScriptMailStore.emails(from: withBody, bodyField: true).first?.body, "the body")
        XCTAssertNil(AppleScriptMailStore.emails(from: withBody, bodyField: false).first?.body)
    }

    func testMalformedRecordsAreSkipped() {
        let fs = AppleScript.fieldSep, rs = AppleScript.recordSep
        let output = ["<m1>", "s", "f", "2026-08-27T10:00:00", "0", "Work"].joined(separator: fs)
            + rs + "garbage-row"
        let items = AppleScriptMailStore.emails(from: output)
        XCTAssertEqual(items.map(\.id), ["<m1>"])
    }

    func testEmptyOutputYieldsNoItems() {
        XCTAssertTrue(AppleScriptMailStore.emails(from: "").isEmpty)
    }
}
