import XCTest
@testable import NotesModule

final class NotesCommandParsingTests: XCTestCase {
    func testListParses() throws {
        _ = try NotesCommand.parseAsRoot(["list", "--folder", "Ideas", "--account", "iCloud", "--limit", "10", "--json"])
    }

    func testSearchRequiresQuery() {
        XCTAssertThrowsError(try NotesCommand.parseAsRoot(["search"]))
        XCTAssertNoThrow(try NotesCommand.parseAsRoot(["search", "brunch"]))
    }

    func testAddRequiresTitle() {
        XCTAssertThrowsError(try NotesCommand.parseAsRoot(["add"]))
        XCTAssertNoThrow(try NotesCommand.parseAsRoot(["add", "Title", "--body", "b"]))
    }

    func testAppendRequiresIDAndText() {
        XCTAssertThrowsError(try NotesCommand.parseAsRoot(["append", "n1"]))
        XCTAssertNoThrow(try NotesCommand.parseAsRoot(["append", "n1", "text"]))
    }

    func testReadParsesHTMLFlag() throws {
        _ = try NotesCommand.parseAsRoot(["read", "n1", "--html", "--json"])
    }
}
