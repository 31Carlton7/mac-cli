import XCTest
@testable import Core

final class MessagingModelsTests: XCTestCase {
    let when = Date(timeIntervalSince1970: 1_787_824_800) // 2026-08-27T10:00:00Z

    func testEmailItemJSONSchema() throws {
        let email = EmailItem(id: "<m1@x>", subject: "Invoice", from: "a@b.com",
                              date: when, isRead: false, account: "Work", body: nil)
        let json = String(data: try Output.encoder.encode(email), encoding: .utf8)!
        XCTAssertEqual(json, #"{"account":"Work","date":"2026-08-27T10:00:00Z","from":"a@b.com","id":"<m1@x>","isRead":false,"subject":"Invoice"}"#)
    }

    func testEmailItemBodyIncludedWhenPresent() throws {
        let email = EmailItem(id: "<m1@x>", subject: "s", from: "f", date: when,
                              isRead: true, account: "A", body: "hello")
        let json = String(data: try Output.encoder.encode(email), encoding: .utf8)!
        XCTAssertTrue(json.contains(#""body":"hello""#))
    }

    func testEmailItemIndexFieldsAreAddedOnlyWhenKnown() throws {
        let email = EmailItem(id: "m1@x", subject: "s", from: "f", date: when,
                              isRead: true, account: "A", body: nil,
                              mailbox: "Inbox", to: ["b@c.com"], isFlagged: true, hasAttachments: false)
        let json = String(data: try Output.encoder.encode(email), encoding: .utf8)!
        XCTAssertEqual(json, #"{"account":"A","date":"2026-08-27T10:00:00Z","from":"f","hasAttachments":false,"id":"m1@x","isFlagged":true,"isRead":true,"mailbox":"Inbox","subject":"s","to":["b@c.com"]}"#)
    }

    func testMessageItemJSONSchema() throws {
        let message = MessageItem(id: "g1", chat: "+15551234567", sender: "+15551234567",
                                  text: "hey", date: when, isFromMe: false)
        let json = String(data: try Output.encoder.encode(message), encoding: .utf8)!
        XCTAssertEqual(json, #"{"chat":"+15551234567","date":"2026-08-27T10:00:00Z","id":"g1","isFromMe":false,"sender":"+15551234567","text":"hey"}"#)
    }

    func testConversationInfoJSONSchema() throws {
        let convo = ConversationInfo(id: "c1", name: "Sarah Chen", lastActivity: when, isGroup: false)
        let json = String(data: try Output.encoder.encode(convo), encoding: .utf8)!
        XCTAssertEqual(json, #"{"id":"c1","isGroup":false,"lastActivity":"2026-08-27T10:00:00Z","name":"Sarah Chen"}"#)
    }

    func testHumanLines() {
        let email = EmailItem(id: "<m1@x>", subject: "Invoice", from: "a@b.com",
                              date: when, isRead: false, account: "Work", body: nil)
        XCTAssertTrue(email.humanLine.hasPrefix("<m1@x>  Invoice  a@b.com  "))
        XCTAssertTrue(email.humanLine.hasSuffix("[unread]"))
        let message = MessageItem(id: "g1", chat: "c", sender: "me", text: "hey", date: when, isFromMe: true)
        XCTAssertTrue(message.humanLine.hasSuffix("me: hey"))
    }
}
