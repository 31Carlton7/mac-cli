import Core
import Foundation

public struct MailDraft: Equatable {
    public var to: String
    public var cc: String?
    public var subject: String
    public var body: String

    public init(to: String, cc: String?, subject: String, body: String) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
    }
}

/// An account and how many messages its inbox holds. The count is the cost
/// proxy the actions layer sorts on: windowing scales with mailbox size, and
/// asking Mail for a mailbox's message count is free.
public struct MailAccountInfo: Equatable {
    public let name: String
    /// -1 when the account has no inbox mailbox at all.
    public let inboxCount: Int

    public init(name: String, inboxCount: Int) {
        self.name = name
        self.inboxCount = inboxCount
    }
}

/// Every read is scoped to one account and bounded by `scan`. There is no
/// whole-inbox query: filtering across Mail's unified inbox is what wedged
/// Mail.app, so selection happens in Swift over a fetched window instead.
public protocol MailStore {
    func accounts() async throws -> [String]
    func accountInboxes() async throws -> [MailAccountInfo]
    /// Newest `scan` messages from that account's inbox, newest first, read flag included.
    func window(account: String, scan: Int) async throws -> [EmailItem]
    /// The message with `id` if it is inside that account's newest `scan`, body populated; nil otherwise.
    func find(id: String, account: String, scan: Int) async throws -> EmailItem?
    /// Returns false when the id isn't inside that account's window.
    func markRead(id: String, account: String, scan: Int) async throws -> Bool
    func archive(id: String, account: String, scan: Int) async throws -> Bool
    func draft(_ draft: MailDraft) async throws
    func send(_ draft: MailDraft) async throws
}
