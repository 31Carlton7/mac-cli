import Core
import Foundation

/// Reads answered from Mail's Envelope Index. Mail.app is asked only for
/// the account list. Every method checks the index before that call, so an
/// unreadable index throws `EnvelopeIndex.Unavailable` without touching Mail.
public struct IndexMailStore {
    let index: EnvelopeIndex
    let directory: MailAccountDirectory

    public init(index: EnvelopeIndex = EnvelopeIndex(),
                directory: MailAccountDirectory = MailAccountDirectory()) {
        self.index = index
        self.directory = directory
    }

    /// Unread inbox mail, newest first. Without `account`, every enabled account.
    public func unread(account: String?, limit: Int) async throws -> [EmailItem] {
        try index.ensureReadable()
        let accounts = try await scope(account)
        let inboxes = try index.inboxes(accountIDs: accounts.map(\.id))
        let messages = try index.unreadMessages(inboxes: Array(inboxes.values), limit: limit)
        return Self.items(messages, accounts: accounts)
    }

    /// Every mailbox of every enabled account except Trash and Junk.
    public func search(query: String, limit: Int) async throws -> [EmailItem] {
        try index.ensureReadable()
        let accounts = try await scope(nil)
        let ids = accounts.map(\.id)
        let mailboxes = try index.mailboxes(accountIDs: ids).filter { !$0.isTrashOrJunk }
        let inboxes = try index.inboxes(accountIDs: ids)
        let messages = try index.search(query, mailboxes: mailboxes,
                                        inboxes: Array(inboxes.values), limit: limit)
        return Self.items(messages, accounts: accounts)
    }

    /// Every account with its inbox size, `-1` when it has none: the order
    /// key the Mail.app window commands sweep by.
    public func accountInboxes() async throws -> [MailAccountInfo] {
        try index.ensureReadable()
        let accounts = try await directory.accounts()
        let inboxes = try index.inboxes(accountIDs: accounts.map(\.id))
        return accounts.map {
            MailAccountInfo(name: $0.name, inboxCount: inboxes[$0.id]?.totalCount ?? -1)
        }
    }

    private func scope(_ account: String?) async throws -> [MailAccount] {
        guard let account else { return try await directory.accounts().filter(\.isEnabled) }
        return [try await directory.account(named: account)]
    }

    static func items(_ messages: [IndexedMessage], accounts: [MailAccount]) -> [EmailItem] {
        let names = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return messages.map { message in
            EmailItem(id: message.messageID, subject: message.subject, from: message.from,
                      date: message.date, isRead: message.isRead,
                      account: names[message.mailbox.accountID] ?? message.mailbox.accountID,
                      body: nil,
                      mailbox: message.isInInbox ? "Inbox" : message.mailbox.path,
                      to: message.to, cc: message.cc,
                      isFlagged: message.isFlagged, hasAttachments: message.hasAttachments)
        }
    }
}
