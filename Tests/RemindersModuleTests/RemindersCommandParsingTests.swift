import XCTest
@testable import RemindersModule

final class RemindersCommandParsingTests: XCTestCase {
    func testListParses() throws {
        _ = try RemindersCommand.parseAsRoot(["list", "--list", "Groceries", "--include-completed", "--json"])
    }

    func testAddParsesPriority() throws {
        _ = try RemindersCommand.parseAsRoot(["add", "Buy milk", "--priority", "high"])
        XCTAssertThrowsError(try RemindersCommand.parseAsRoot(["add", "Buy milk", "--priority", "urgent"]))
    }

    func testCompleteRequiresID() {
        XCTAssertThrowsError(try RemindersCommand.parseAsRoot(["complete"]))
        XCTAssertNoThrow(try RemindersCommand.parseAsRoot(["complete", "some-id"]))
    }
}
