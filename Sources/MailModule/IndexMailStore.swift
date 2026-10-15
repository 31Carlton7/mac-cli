import Core
import Foundation

/// Reads answered from Mail's Envelope Index and message files. Mail.app is
/// asked only for the account list. Every method checks the index before
/// that call, so an unreadable index throws `EnvelopeIndex.Unavailable`
/// without touching Mail.
public struct IndexMailStore {
    /// The index has the message but its file is missing or does not decode.
    public struct FileUnreadable: Error {
        public let message: IndexedMessage
        public let accounts: [MailAccount]
        public let error: MacError
    }

    let index: EnvelopeIndex
    let directory: MailAccountDirectory
    let files: () throws -> MailMessageFiles

    public init(index: EnvelopeIndex = EnvelopeIndex(),
                directory: MailAccountDirectory = MailAccountDirectory(),
                files: @escaping () throws -> MailMessageFiles = { try MailMessageFiles.newest() }) {
        self.index = index
        self.directory = directory
        self.files = files
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

    /// One message with its body, decoded from its file. A message copied
    /// into several mailboxes is read from its inbox copy, then the newest.
    public func read(id: String) async throws -> EmailItem {
        try index.ensureReadable()
        guard let message = Self.preferredCopy(try index.messages(withID: id)) else {
            throw MacError(.notFound, "No message with id \(EnvelopeIndex.bareMessageID(id)) in Mail's Envelope Index. List it again with: mac mail unread")
        }
        let accounts = try await directory.accounts()
        let decoded: EmlxMessage
        do {
            // The row's own mailbox holds the file: All Mail for a Gmail
            // message, even one shown in the inbox through a label.
            decoded = try files().message(accountID: message.mailbox.accountID,
                                          mailboxURL: message.mailbox.url, rowID: message.rowID)
        } catch let error as MacError {
            throw FileUnreadable(message: message, accounts: accounts, error: error)
        }
        return Self.item(message, accounts: accounts, body: decoded.body,
                         attachments: decoded.attachments.map {
                             EmailAttachment(name: $0.name, mimeType: $0.mimeType, size: $0.size, isExternal: $0.isExternal)
                         })
    }

    /// Rows come newest first.
    static func preferredCopy(_ copies: [IndexedMessage]) -> IndexedMessage? {
        copies.first(where: \.isInInbox) ?? copies.first
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
        messages.map { item($0, accounts: accounts) }
    }

    static func item(_ message: IndexedMessage, accounts: [MailAccount], body: String? = nil,
                     attachments: [EmailAttachment]? = nil) -> EmailItem {
        let name = accounts.first { $0.id == message.mailbox.accountID }?.name
        return EmailItem(id: message.messageID, subject: message.subject, from: message.from,
                         date: message.date, isRead: message.isRead,
                         account: name ?? message.mailbox.accountID,
                         body: body,
                         mailbox: message.isInInbox ? "Inbox" : message.mailbox.path,
                         to: message.to, cc: message.cc,
                         isFlagged: message.isFlagged, hasAttachments: message.hasAttachments,
                         attachments: attachments)
    }
}
