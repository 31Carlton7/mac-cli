import XCTest
import Core
@testable import MessagesModule

final class MockMessageStore: MessageStore {
    var accessGranted = true
    var storedConversations: [ConversationInfo] = []
    var storedMessages: [MessageItem] = []
    var sent: [(handle: String, text: String)] = []

    private func gate() throws {
        if !accessGranted {
            throw MacError(.permissionDenied, "Cannot read Messages database. Run: mac doctor")
        }
    }

    func conversations(limit: Int) async throws -> [ConversationInfo] {
        try gate()
        return Array(storedConversations.prefix(limit))
    }

    func history(handle: String, limit: Int) async throws -> [MessageItem] {
        try gate()
        return Array(storedMessages.filter { $0.chat == handle }.prefix(limit))
    }

    func send(handle: String, text: String) async throws {
        try gate()
        sent.append((handle, text))
    }
}

final class MessageActionsTests: XCTestCase {
    var store = MockMessageStore()
    lazy var actions = MessageActions(store: store)
    let base = Date(timeIntervalSince1970: 1_787_824_800)

    func message(_ id: String, offset: TimeInterval) -> MessageItem {
        MessageItem(id: id, chat: "+15551234567", sender: "+15551234567",
                    text: id, date: base.addingTimeInterval(offset), isFromMe: false)
    }

    func testHistorySortsOldestToNewest() async throws {
        store.storedMessages = [message("newest", offset: 100), message("oldest", offset: 0),
                                message("middle", offset: 50)]
        let items = try await actions.history(handle: "+15551234567", limit: 30)
        XCTAssertEqual(items.map(\.id), ["oldest", "middle", "newest"])
    }

    func testEmptyHandleThrowsBadInput() async {
        do {
            _ = try await actions.history(handle: "  ", limit: 30)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testSendEmptyTextThrowsBadInput() async {
        do {
            try await actions.send(handle: "+15551234567", text: "  ")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testLimitOutOfRangeThrowsBadInput() async {
        do {
            _ = try await actions.conversations(limit: 0)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testSendPassesThrough() async throws {
        try await actions.send(handle: "+15551234567", text: "hello")
        XCTAssertEqual(store.sent.count, 1)
        XCTAssertEqual(store.sent[0].text, "hello")
    }

    func testPermissionDeniedPropagates() async {
        store.accessGranted = false
        do {
            _ = try await actions.conversations(limit: 5)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }
}
