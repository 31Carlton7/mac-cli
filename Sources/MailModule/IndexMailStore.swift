import Core
import Foundation

/// Reads answered from Mail's Envelope Index, and mutations resolved through
/// it. Mail.app is asked for the account list, and runs a mutation only once
/// every target is resolved. Every method checks the index before that call,
/// so an unreadable index throws `EnvelopeIndex.Unavailable` without touching Mail.
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
    /// Runs a Mail.app script for a mutation and returns its output.
    let runScript: (String) async throws -> String
    /// How long to wait for the index to show a change Mail reported.
    let settle: TimeInterval

    public init(index: EnvelopeIndex = EnvelopeIndex(),
                directory: MailAccountDirectory = MailAccountDirectory(),
                files: @escaping () throws -> MailMessageFiles = { try MailMessageFiles.newest() }) {
        self.init(index: index, directory: directory, files: files,
                  runScript: { try await AppleScript.run($0, targetName: "Mail") })
    }

    init(index: EnvelopeIndex, directory: MailAccountDirectory,
         files: @escaping () throws -> MailMessageFiles = { try MailMessageFiles.newest() },
         runScript: @escaping (String) async throws -> String, settle: TimeInterval = 2) {
        self.index = index
        self.directory = directory
        self.files = files
        self.runScript = runScript
        self.settle = settle
    }

    /// Unread inbox mail, newest first. Without `account`, every enabled account.
    public func unread(account: String?, limit: Int) async throws -> [EmailItem] {
        try index.ensureReadable()
        let accounts = try await scope(account)
        let inboxes = try index.inboxes(accountIDs: accounts.map(\.id))
        let messages = try index.unreadMessages(inboxes: Array(inboxes.values), limit: limit)
        return Self.items(messages, accounts: accounts)
    }

    /// Every mailbox of every enabled account, plus any account the query
    /// names. Trash and Junk are left out unless the query asks for a mailbox.
    public func search(_ query: MailQuery, limit: Int) async throws -> [EmailItem] {
        try index.ensureReadable()
        let all = try await directory.accounts(knowing: query.accountNames)
        let named = Set(query.accountNames.map { $0.lowercased() })
        let accounts = all.filter { $0.isEnabled || named.contains($0.name.lowercased()) }
        let accountIDs = Dictionary(all.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let clause = try query.sql(accountIDs: accountIDs)
        let ids = accounts.map(\.id)
        let mailboxes = try index.mailboxes(accountIDs: ids)
            .filter { query.namesMailbox || !$0.isTrashOrJunk }
        let inboxes = try index.inboxes(accountIDs: ids)
        let messages = try index.search(clause, mailboxes: mailboxes,
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

    // MARK: - Mutations

    /// Resolves every id to exactly one live row before anything changes.
    /// An id with no row in scope is `notFound`, one with several is
    /// `badInput`; either fails the whole call, so no mutation target is
    /// ever guessed.
    public func targets(for mutation: MailMutation, ids: [String], account: String?,
                        mailbox: String?) async throws -> [MailTarget] {
        try index.ensureReadable()
        let accounts = try await directory.accounts(knowing: account.map { [$0] } ?? [])
        let only = try account.map { try MailAccountDirectory.account(named: $0, in: accounts) }
        let names = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var mailboxesByAccount: [String: [IndexMailbox]]?
        var seen: Set<String> = []
        var out: [MailTarget] = []
        for raw in ids {
            let id = EnvelopeIndex.bareMessageID(raw)
            guard !id.isEmpty else { throw MacError(.badInput, "Message ids cannot be empty.") }
            guard seen.insert(id).inserted else { continue }
            let copies = try index.messages(withID: id)
            let labels = try index.labels(ofMessages: copies.map(\.rowID))
            let inScope = copies.filter { copy in
                (only.map { copy.mailbox.accountID == $0.id } ?? true)
                    && (mailbox.map { Self.copy(copy, labels: labels[copy.rowID] ?? [], isIn: $0) } ?? true)
            }
            guard let message = inScope.first else {
                if copies.isEmpty {
                    throw MacError(.notFound, "No message with id \(id) in Mail. List it again with: mac mail search")
                }
                throw MacError(.notFound, "Message \(id) is not in that \(mailbox == nil ? "account" : "mailbox"). It is in: \(Self.places(copies, names: names)).")
            }
            guard inScope.count == 1 else {
                let advice: String
                if Set(inScope.map(\.mailbox.accountID)).count > 1 {
                    advice = "Pick one with --account."
                } else if Set(inScope.map(\.mailbox.rowID)).count > 1 {
                    advice = "Pick one with --mailbox."
                } else {
                    advice = "They share one mailbox, so mac cannot tell them apart; act on it in Mail."
                }
                throw MacError(.badInput, "Message \(id) has \(inScope.count) copies: \(Self.places(inScope, names: names)). \(advice)")
            }
            guard let owner = accounts.first(where: { $0.id == message.mailbox.accountID }) else {
                throw MacError(.badInput, "Message \(id) is in a mailbox that belongs to no Mail account, such as On My Mac. mac cannot act on it.")
            }
            guard owner.isEnabled else {
                throw MacError(.badInput, "Message \(id) is in account '\(owner.name)', which is disabled in Mail.")
            }
            if mailboxesByAccount == nil {
                mailboxesByAccount = Dictionary(grouping: try index.mailboxes(accountIDs: accounts.map(\.id)),
                                                by: \.accountID)
            }
            let accountMailboxes = mailboxesByAccount?[owner.id] ?? []
            let target = MailTarget(account: owner, message: message, destination: nil)
            out.append(MailTarget(account: owner, message: message, destination: try Self.destination(
                for: mutation, target: target, labels: labels[message.rowID] ?? [],
                storesLabels: Self.storesLabels(accountMailboxes) || labels[message.rowID] != nil,
                mailboxes: accountMailboxes)))
        }
        return out
    }

    /// Runs one Mail.app script per account, then waits up to `settle` for
    /// the index to show each reported change. Once a script has run, its
    /// receipt is returned: later failures become per-id results or notices.
    public func perform(_ mutation: MailMutation, on targets: [MailTarget],
                        notice: (String) -> Void) async throws -> [MailActionResult] {
        var results = targets.map { $0.result(.failed) }
        var accountOrder: [String] = []
        var positions: [String: [Int]] = [:]
        for (i, target) in targets.enumerated() {
            if positions[target.account.id] == nil { accountOrder.append(target.account.id) }
            positions[target.account.id, default: []].append(i)
        }
        var firstError: Error?
        var anyRan = false
        for accountID in accountOrder {
            let mine = positions[accountID] ?? []
            let script = MailScripts.act(mutation, accountID: accountID, targets: mine.map {
                MailScripts.ActionTarget(rowID: targets[$0].message.rowID,
                                         mailbox: targets[$0].message.mailbox.path,
                                         destination: targets[$0].destination?.path)
            })
            let statuses: [Int64: MailScripts.ActionStatus]
            do {
                statuses = MailScripts.actionStatuses(from: try await runScript(script))
                anyRan = true
            } catch {
                firstError = firstError ?? error
                for i in mine { results[i].detail = Self.describe(error) }
                continue
            }
            for i in mine {
                switch statuses[targets[i].message.rowID] {
                case .ok?: results[i].status = .ok
                case .notFound?: results[i].status = .notFound
                case .failed(let reason)?: results[i].detail = reason
                case nil: results[i].detail = "Mail did not report on this message."
                }
            }
        }
        if !anyRan, let firstError { throw firstError }

        let reported = results.indices.filter { results[$0].status == .ok }
        do {
            for i in try await visible(mutation, targets: targets, among: reported) {
                results[i].verified = true
            }
        } catch {
            notice("warning: could not check the result in Mail's Envelope Index: \(Self.describe(error))")
        }
        return results
    }

    /// Which of `positions` the index shows changed, polling until all are
    /// or `settle` runs out. Mail writes its index shortly after it acts.
    private func visible(_ mutation: MailMutation, targets: [MailTarget],
                         among positions: [Int]) async throws -> Set<Int> {
        var waiting = Set(positions)
        var done: Set<Int> = []
        let deadline = Date().addingTimeInterval(settle)
        while !waiting.isEmpty {
            for i in waiting {
                let copies = try index.messages(withID: targets[i].message.messageID)
                let labels = try index.labels(ofMessages: copies.map(\.rowID))
                if mutation.isVisible(on: targets[i], in: copies, labels: labels) { done.insert(i) }
            }
            waiting.subtract(done)
            guard !waiting.isEmpty, Date() < deadline else { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return done
    }

    /// Where a move sends `target`, or nil for a change that stays put.
    /// `labels` are the Gmail label mailboxes the message carries.
    static func destination(for mutation: MailMutation, target: MailTarget, labels: [IndexMailbox],
                            storesLabels: Bool, mailboxes: [IndexMailbox]) throws -> IndexMailbox? {
        let id = target.message.messageID
        let account = target.account.name
        let destination: IndexMailbox
        switch mutation {
        case .markRead, .markUnread, .flag, .unflag:
            return nil
        case .archive:
            // Gmail archives by removing the Inbox label. Mail keeps the
            // message once, in All Mail, so a scripted move to All Mail moves
            // it onto itself and can leave the label on the server. Only
            // Mail's own Archive command does it, and that needs its windows.
            if storesLabels {
                throw MacError(.badInput, "Message \(id) is in Gmail account '\(account)'. Gmail archives by removing the Inbox label, which Mail does reliably only through its own Archive command; archive it in Mail.")
            }
            let archives = mailboxes.filter { $0.path.lowercased() == "archive" }
            guard let archive = archives.first else {
                throw MacError(.notFound, "Account '\(account)' has no Archive mailbox.")
            }
            guard archives.count == 1 else {
                throw MacError(.badInput, "Account '\(account)' has \(archives.count) mailboxes named Archive.")
            }
            destination = archive
        case .move(let name):
            // A Gmail mailbox is a label: moving means removing one label and
            // adding another, and a scripted move acts on the All Mail copy.
            if storesLabels {
                throw MacError(.badInput, "Message \(id) is in Gmail account '\(account)', where a mailbox is a label. mac does not change Gmail labels yet; move it in Mail.")
            }
            destination = try mailbox(named: name, in: mailboxes, account: account)
        case .delete:
            let trashes = mailboxes.filter(\.isTrash)
            guard let trash = trashes.first else {
                throw MacError(.notFound, "Account '\(account)' has no Trash mailbox.")
            }
            guard trashes.count == 1 else {
                throw MacError(.badInput, "Account '\(account)' has \(trashes.count) Trash mailboxes (\(trashes.map(\.path).joined(separator: ", "))), so mac cannot tell which one Mail uses.")
            }
            // Mail's Delete on a message already in Trash erases it.
            if labels.contains(where: { $0.rowID == trash.rowID }) {
                throw MacError(.badInput, "Message \(id) is already in \(trash.path). mac never erases mail.")
            }
            destination = trash
        }
        guard destination.rowID != target.message.mailbox.rowID else {
            throw MacError(.badInput, "Message \(id) is already in \(destination.path).\(mutation == .delete ? " mac never erases mail." : "")")
        }
        return destination
    }

    /// `--to` by full path, exact case first, then case-insensitive when only
    /// one mailbox matches that way, then by last path component when only one
    /// mailbox of the account has it.
    static func mailbox(named name: String, in mailboxes: [IndexMailbox], account: String) throws -> IndexMailbox {
        if let exact = mailboxes.first(where: { $0.path == name }) { return exact }
        let wanted = name.lowercased()
        let paths = mailboxes.filter { $0.path.lowercased() == wanted }
        guard paths.count <= 1 else {
            throw MacError(.badInput, "Account '\(account)' has \(paths.count) mailboxes named '\(name)' in different case: \(paths.map(\.path).joined(separator: ", ")). Give the exact name.")
        }
        if let path = paths.first { return path }
        let leaves = mailboxes.filter { $0.leaf.lowercased() == wanted }
        guard let match = leaves.first else {
            throw MacError(.notFound, "Account '\(account)' has no mailbox named '\(name)'.")
        }
        guard leaves.count == 1 else {
            throw MacError(.badInput, "Account '\(account)' has \(leaves.count) mailboxes named '\(name)': \(leaves.map(\.path).joined(separator: ", ")). Give the full path.")
        }
        return match
    }

    /// Gmail and Google Workspace keep every message once in All Mail and
    /// file it elsewhere with labels.
    static func storesLabels(_ mailboxes: [IndexMailbox]) -> Bool {
        mailboxes.contains { $0.path.hasPrefix("[Gmail]/") || $0.path.hasPrefix("[Google Mail]/") }
    }

    /// `--mailbox` matches a row's own mailbox, a Gmail label it carries, or
    /// `Inbox` for any inbox copy. Case-insensitive, by full path.
    static func copy(_ copy: IndexedMessage, labels: [IndexMailbox], isIn name: String) -> Bool {
        let wanted = name.lowercased()
        if wanted == "inbox" { return copy.isInInbox }
        return ([copy.mailbox] + labels).contains { $0.path.lowercased() == wanted }
    }

    static func places(_ copies: [IndexedMessage], names: [String: String]) -> String {
        copies.map { copy in
            let place = copy.isInInbox ? "Inbox" : copy.mailbox.path
            return "\(names[copy.mailbox.accountID] ?? copy.mailbox.accountID)/\(place)"
        }.joined(separator: ", ")
    }

    static func describe(_ error: Error) -> String {
        (error as? MacError)?.message ?? error.localizedDescription
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
