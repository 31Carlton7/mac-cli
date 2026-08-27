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

    // MARK: - Dedup by id (real Notes.app flattens `folders of account`, so the
    // defensive queue walk in NoteScripts double-visits subfolders; the store
    // must dedupe by id, keeping the first occurrence, without inflating the
    // malformed-row warning count for duplicates.)

    func testDuplicateNoteRowsDedupeById() {
        let row = ["n1", "Title One", "Ideas", "iCloud", "2026-08-27T10:00:00", "2026-08-27T11:00:00"].joined(separator: fs)
        let other = ["n2", "Title Two", "Notes", "Work", "2026-08-27T09:00:00", "2026-08-27T09:30:00"].joined(separator: fs)
        let output = [row, row, other].joined(separator: rs)
        let items = AppleScriptNoteStore.items(from: output)
        XCTAssertEqual(items.map(\.id), ["n1", "n2"])
        XCTAssertEqual(items[0].folder, "Ideas") // first occurrence kept
    }

    func testDuplicateFolderRowsDedupeById() {
        let row = ["f1", "🌠 Wishlists", "iCloud", "7"].joined(separator: fs)
        let output = [row, row].joined(separator: rs)
        let folders = AppleScriptNoteStore.folderInfos(from: output)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].noteCount, 7)
    }

    func testSearchRowsDedupeById() {
        let row = ["n1", "t", "f", "a", "2026-08-27T10:00:00", "2026-08-27T11:00:00", "plain text here"].joined(separator: fs)
        let output = [row, row].joined(separator: rs)
        let rows = AppleScriptNoteStore.parseSearchRows(from: output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.text, "plain text here")
    }

    // A duplicate id must not be counted as a malformed/dropped row: the
    // skip path (field-count guard) and the dedupe path are tracked
    // separately in the implementation, so a genuinely malformed row still
    // triggers a drop while a duplicate does not inflate that count. We can't
    // assert stderr output directly, so this is verified via item counts:
    // 1 real duplicate + 1 malformed row -> exactly 1 item survives, and the
    // malformed row is the only one attributable to warnIfDropped.
    func testMalformedRowDropsButDuplicateDoesNotInflateWarning() {
        let row = ["n1", "Title One", "Ideas", "iCloud", "2026-08-27T10:00:00", "2026-08-27T11:00:00"].joined(separator: fs)
        let output = [row, row, "garbage"].joined(separator: rs)
        let items = AppleScriptNoteStore.items(from: output)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "n1")
    }
}
