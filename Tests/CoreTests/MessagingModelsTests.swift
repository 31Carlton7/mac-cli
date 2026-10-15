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

    func testEmailItemAttachmentsAreListedOnlyWhenKnown() throws {
        let email = EmailItem(id: "m1@x", subject: "s", from: "f", date: when,
                              isRead: true, account: "A", body: "b",
                              attachments: [EmailAttachment(name: "a.pdf", mimeType: "application/pdf", size: 12, isExternal: false),
                                            EmailAttachment(name: nil, mimeType: "image/png", size: 3, isExternal: true)])
        let json = String(data: try Output.encoder.encode(email), encoding: .utf8)!
        XCTAssertEqual(json, #"{"account":"A","attachments":[{"isExternal":false,"mimeType":"application\/pdf","name":"a.pdf","size":12},{"isExternal":true,"mimeType":"image\/png","size":3}],"body":"b","date":"2026-08-27T10:00:00Z","from":"f","id":"m1@x","isRead":true,"subject":"s"}"#)
    }

    func testEmailItemOnDeviceFieldsAreAddedOnlyWhenKnown() throws {
        let email = EmailItem(id: "m1@x", subject: "s", from: "f", date: when,
                              isRead: true, account: "A", body: nil,
                              category: "updates", summary: "A short summary.", isPriority: false)
        let json = String(data: try Output.encoder.encode(email), encoding: .utf8)!
        XCTAssertEqual(json, #"{"account":"A","category":"updates","date":"2026-08-27T10:00:00Z","from":"f","id":"m1@x","isPriority":false,"isRead":true,"subject":"s","summary":"A short summary."}"#)
    }

    func testEmailHumanLineTagsCategoryAndPriorityButNotTheSummary() {
        func line(_ category: String?, priority: Bool? = nil) -> String {
            EmailItem(id: "m1@x", subject: "s", from: "f", date: when, isRead: false, account: "A",
                      body: nil, category: category, summary: "never shown", isPriority: priority).humanLine
        }
        XCTAssertTrue(line("promotions").hasSuffix("  [unread]  [promotions]"))
        XCTAssertTrue(line("primary").hasSuffix("  [unread]"), "primary is the default and goes untagged")
        XCTAssertTrue(line("transactions", priority: true).hasSuffix("  [unread]  [priority]  [transactions]"))
        XCTAssertFalse(line("updates").contains("never shown"))
    }

    func testMailSenderJSONCarriesOnlyItsGrouping() throws {
        let sender = MailSender(domain: "shop.example", name: nil, count: 12, unreadCount: 3, latest: when)
        let json = String(data: try Output.encoder.encode(sender), encoding: .utf8)!
        XCTAssertEqual(json, #"{"count":12,"domain":"shop.example","latest":"2026-08-27T10:00:00Z","unreadCount":3}"#)
        let named = MailSender(address: "news@shop.example", name: "Shop", count: 12, unreadCount: 3, latest: when)
        XCTAssertTrue(named.humanLine.hasPrefix("12  news@shop.example  Shop  3 unread  latest "))
        XCTAssertTrue(sender.humanLine.hasPrefix("12  shop.example  3 unread  latest "))
    }

    func testMailContactJSONSchema() throws {
        let contact = MailContact(address: "ann@corp.example", name: "Ann Lee", messageCount: 5, lastContact: when)
        let json = String(data: try Output.encoder.encode(contact), encoding: .utf8)!
        XCTAssertEqual(json, #"{"address":"ann@corp.example","lastContact":"2026-08-27T10:00:00Z","messageCount":5,"name":"Ann Lee"}"#)
        XCTAssertTrue(contact.humanLine.hasPrefix("5  ann@corp.example  Ann Lee  last "))
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
