import XCTest
@testable import MessagesModule

final class MessagesCommandParsingTests: XCTestCase {
    func testChatsParses() throws {
        _ = try MessagesCommand.parseAsRoot(["chats", "--limit", "10", "--json"])
    }

    func testHistoryRequiresHandle() {
        XCTAssertThrowsError(try MessagesCommand.parseAsRoot(["history"]))
        XCTAssertNoThrow(try MessagesCommand.parseAsRoot(["history", "+15551234567"]))
    }

    func testSendRequiresHandleAndText() {
        XCTAssertThrowsError(try MessagesCommand.parseAsRoot(["send", "+15551234567"]))
        XCTAssertNoThrow(try MessagesCommand.parseAsRoot(["send", "+15551234567", "hello"]))
        XCTAssertNoThrow(try MessagesCommand.parseAsRoot(["send", "+15551234567", "hello", "--dry-run", "--json"]))
        XCTAssertNoThrow(try MessagesCommand.parseAsRoot(["send", "+15551234567", "hello", "--verify"]))
    }

    func testSearchRequiresQueryAndAcceptsBounds() {
        XCTAssertThrowsError(try MessagesCommand.parseAsRoot(["search"]))
        XCTAssertNoThrow(try MessagesCommand.parseAsRoot([
            "search", "reservation", "--chat", "+15551234567", "--limit", "10", "--scan", "1000", "--json"
        ]))
    }
}
