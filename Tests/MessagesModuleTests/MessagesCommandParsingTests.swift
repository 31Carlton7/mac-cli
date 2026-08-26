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
    }
}
