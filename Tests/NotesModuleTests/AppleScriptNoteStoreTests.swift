import XCTest
import Core
@testable import NotesModule

final class AppleScriptNoteStoreTests: XCTestCase {
    let fs = AppleScript.fieldSep, rs = AppleScript.recordSep

    func testParsesNoteRows() {
        let output = ["n1", "Title One", "Ideas", "iCloud", "2026-08-27T10:00:00", "2026-08-27T11:00:00"].joined(separator: fs)
            + rs + ["n2", "Title Two", "Notes", "Work", "2026-08-27T09:00:00", "2026-08-27T09:30:00"].joined(separator: fs)
        let items = AppleScriptNoteStore.items(from: output)
        XCTAssertEqual(items.map(\.id), ["n1", "n2"])
        XCTAssertEqual(items[0].folder, "Ideas")
        XCTAssertEqual(items[1].account, "Work")
        XCTAssertNil(items[0].body)
    }

    func testParsesBodyFieldOnlyWhenRequested() {
        let row = ["n1", "t", "f", "a", "2026-08-27T10:00:00", "2026-08-27T11:00:00", "the body"].joined(separator: fs)
        XCTAssertEqual(AppleScriptNoteStore.items(from: row, bodyField: true).first?.body, "the body")
        XCTAssertNil(AppleScriptNoteStore.items(from: row, bodyField: false).first?.body)
    }

    func testParsesSearchRows() {
        let row = ["n1", "t", "f", "a", "2026-08-27T10:00:00", "2026-08-27T11:00:00", "plain text here"].joined(separator: fs)
        let rows = AppleScriptNoteStore.parseSearchRows(from: row)
        XCTAssertEqual(rows.first?.text, "plain text here")
        XCTAssertNil(rows.first?.item.body)
    }

    func testParsesFolderRowsAndSkipsMalformed() {
        let output = ["f1", "Ideas", "iCloud", "7"].joined(separator: fs) + rs + "garbage"
        let folders = AppleScriptNoteStore.folderInfos(from: output)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].noteCount, 7)
    }

    func testEmptyOutputYieldsNothing() {
        XCTAssertTrue(AppleScriptNoteStore.items(from: "").isEmpty)
        XCTAssertTrue(AppleScriptNoteStore.folderInfos(from: "").isEmpty)
    }
}
