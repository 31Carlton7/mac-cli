import Core
import Foundation

/// One row of `mac mail mailboxes`.
public struct MailboxSummary: Codable, Equatable, HumanRenderable {
    public let account: String
    /// What `--mailbox` and `in:` accept, e.g. `INBOX` or `[Gmail]/Sent Mail`.
    public let path: String
    public let total: Int
    public let unread: Int

    public init(account: String, path: String, total: Int, unread: Int) {
        self.account = account
        self.path = path
        self.total = total
        self.unread = unread
    }

    public var humanLine: String {
        "\(account)  \(path)  \(total)  \(unread)"
    }

    /// Aligned columns under a header; empty when there are no rows.
    public static func table(_ rows: [MailboxSummary]) -> String {
        guard !rows.isEmpty else { return "" }
        let accountWidth = max(7, rows.map(\.account.count).max()!)
        let pathWidth = max(7, rows.map(\.path.count).max()!)
        let totalWidth = max(5, rows.map { String($0.total).count }.max()!)
        let unreadWidth = max(6, rows.map { String($0.unread).count }.max()!)
        func line(_ cells: [String]) -> String {
            let account = cells[0].padding(toLength: accountWidth, withPad: " ", startingAt: 0)
            let path = cells[1].padding(toLength: pathWidth, withPad: " ", startingAt: 0)
            let total = String(repeating: " ", count: totalWidth - cells[2].count) + cells[2]
            let unread = String(repeating: " ", count: unreadWidth - cells[3].count) + cells[3]
            return "\(account)  \(path)  \(total)  \(unread)"
        }
        return ([line(["ACCOUNT", "MAILBOX", "TOTAL", "UNREAD"])]
            + rows.map { line([$0.account, $0.path, String($0.total), String($0.unread)]) })
            .joined(separator: "\n")
    }
}

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
        return try search(query, accounts: try await directory.accounts(knowing: query.accountNames), limit: limit)
    }

    /// The newest messages of the mailbox `mailbox` names, by the rules of
    /// `in:`, in `account` or every enabled account, that match `filters`.
    /// A name that picks no mailbox there is `notFound`, not an empty list.
    public func list(_ filters: [MailQuery.Term], mailbox: String, account: String?,
                     limit: Int) async throws -> [EmailItem] {
        try index.ensureReadable()
        let all = try await directory.accounts(knowing: (account.map { [$0] } ?? []) + MailQuery(terms: filters).accountNames)
        let terms = filters + (try scopeTerms(mailbox: mailbox, account: account, accounts: all))
        return try search(MailQuery(terms: terms), accounts: all, limit: limit)
    }

    /// Starts noticing mail that arrives from now on, for `wait` and `watch`.
    /// The scope is `list`'s: `mailbox` (default: every inbox, unless the
    /// filters name one with `in:`) in `account` or every enabled account.
    /// This is the only Mail.app call; polling reads the index alone.
    public func arrivals(_ filters: [MailQuery.Term], mailbox: String?,
                         account: String?) async throws -> MailArrivals {
        try index.ensureReadable()
        let all = try await directory.accounts(knowing: (account.map { [$0] } ?? []) + MailQuery(terms: filters).accountNames)
        let name = mailbox ?? (MailQuery(terms: filters).namesMailbox ? nil : "inbox")
        let terms = filters + (try scopeTerms(mailbox: name, account: account, accounts: all))
        return MailArrivals(store: self, query: MailQuery(terms: terms), accounts: all,
                            start: try index.newestRowID())
    }

    /// The terms `--mailbox` and `--account` add. A mailbox name that picks
    /// no mailbox in that scope is `notFound`, not an empty result.
    private func scopeTerms(mailbox: String?, account: String?,
                            accounts all: [MailAccount]) throws -> [MailQuery.Term] {
        let scope = try account.map { [try MailAccountDirectory.account(named: $0, in: all)] }
            ?? all.filter(\.isEnabled)
        var terms: [MailQuery.Term] = []
        if let mailbox {
            if try index.mailboxes(named: mailbox, accountIDs: scope.map(\.id)).isEmpty {
                let place = account == nil ? "any enabled account" : scope[0].name
                throw MacError(.notFound, "No mailbox '\(mailbox)' in \(place). Run: mac mail mailboxes")
            }
            terms.append(MailQuery.Term(.mailbox(mailbox)))
        }
        if account != nil { terms.append(MailQuery.Term(.account(scope[0].name))) }
        return terms
    }

    /// Every mailbox of `account`, or of every enabled account, with its
    /// total and unread counts: accounts in Mail's order, each inbox first.
    /// Unless `all`, empty system mailboxes such as Exchange's Journal or
    /// Gmail's Starred are left out. Empty mailboxes you made stay listed.
    public func mailboxes(account: String?, all: Bool) async throws -> [MailboxSummary] {
        try index.ensureReadable()
        let accounts = try await scope(account)
        let mailboxes = try index.mailboxes(accountIDs: accounts.map(\.id)).filter {
            all || $0.totalCount > 0 || $0.isInbox || !MailboxActions.isSpecial($0.path)
        }
        let unread = try index.unreadCounts(mailboxes: mailboxes)
        let byAccount = Dictionary(grouping: mailboxes, by: \.accountID)
        return accounts.flatMap { account in
            (byAccount[account.id] ?? [])
                .sorted { ($0.isInbox ? 0 : 1, $0.path.lowercased()) < ($1.isInbox ? 0 : 1, $1.path.lowercased()) }
                .map { MailboxSummary(account: account.name, path: $0.path, total: $0.totalCount,
                                      unread: unread[$0.rowID] ?? 0) }
        }
    }

    private func search(_ query: MailQuery, accounts all: [MailAccount], limit: Int) throws -> [EmailItem] {
        Self.items(try matches(query, accounts: all, limit: limit), accounts: all)
    }

    /// The rows `search` reads. With `after`, only rows with a higher ROWID,
    /// in arrival order.
    func matches(_ query: MailQuery, accounts all: [MailAccount], limit: Int?,
                 after rowID: Int64? = nil) throws -> [IndexedMessage] {
        let named = Set(query.accountNames.map { $0.lowercased() })
        let accounts = all.filter { $0.isEnabled || named.contains($0.name.lowercased()) }
        let accountIDs = Dictionary(all.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let clause = try query.sql(accountIDs: accountIDs)
        let ids = accounts.map(\.id)
        let mailboxes = try index.mailboxes(accountIDs: ids)
            .filter { query.namesMailbox || !$0.isTrashOrJunk }
        let inboxes = try index.inboxes(accountIDs: ids)
        return try index.search(clause, mailboxes: mailboxes, inboxes: Array(inboxes.values),
                                limit: limit, after: rowID)
    }

    /// One message with its body, decoded from its file. A message copied
    /// into several mailboxes is read from its inbox copy, then the newest.
    public func read(id: String) async throws -> EmailItem {
        let message = try indexedMessage(id: id)
        let accounts = try await directory.accounts()
        let decoded: EmlxMessage
        do {
            decoded = try file(of: message)
        } catch let error as MacError {
            throw FileUnreadable(message: message, accounts: accounts, error: error)
        }
        return Self.item(message, accounts: accounts, body: decoded.body,
                         attachments: decoded.attachments.map {
                             EmailAttachment(name: $0.name, mimeType: $0.mimeType, size: $0.size, isExternal: $0.isExternal)
                         })
    }

    /// The decoded file of the message `read` shows for `id`, without asking
    /// Mail.app for anything.
    public func file(id: String) throws -> EmlxMessage {
        try file(of: try indexedMessage(id: id))
    }

    private func indexedMessage(id: String) throws -> IndexedMessage {
        try index.ensureReadable()
        guard let message = Self.preferredCopy(try index.messages(withID: id)) else {
            throw MacError(.notFound, "No message with id \(EnvelopeIndex.bareMessageID(id)) in Mail's Envelope Index. List it again with: mac mail unread")
        }
        return message
    }

    /// The row's own mailbox holds the file: All Mail for a Gmail message,
    /// even one shown in the inbox through a label.
    func file(of message: IndexedMessage) throws -> EmlxMessage {
        try files().message(accountID: message.mailbox.accountID,
                            mailboxURL: message.mailbox.url, rowID: message.rowID)
    }

    /// Rows come newest first.
    static func preferredCopy(_ copies: [IndexedMessage]) -> IndexedMessage? {
        copies.first(where: \.isInInbox) ?? copies.first
    }

    /// Who sends the most mail to every inbox of every enabled account, or
    /// to the mailboxes `query` names with `in:`.
    public func senders(matching query: MailQuery?, unreadOnly: Bool, by grouping: SenderGrouping,
                        account: String?, limit: Int) async throws -> [MailSender] {
        try index.ensureReadable()
        let all = try await directory.accounts(knowing: (account.map { [$0] } ?? []) + (query?.accountNames ?? []))
        let accounts: [MailAccount]
        if let account {
            accounts = [try MailAccountDirectory.account(named: account, in: all)]
        } else {
            let named = Set((query?.accountNames ?? []).map { $0.lowercased() })
            accounts = all.filter { $0.isEnabled || named.contains($0.name.lowercased()) }
        }
        let accountIDs = Dictionary(all.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        var clause = try query?.sql(accountIDs: accountIDs) ?? MailQuerySQL(sql: "")
        if unreadOnly {
            clause.sql = clause.sql.isEmpty ? "m.read = 0" : "(\(clause.sql)) AND m.read = 0"
        }
        let ids = accounts.map(\.id)
        let mailboxes = query?.namesMailbox == true
            ? try index.mailboxes(accountIDs: ids)
            : Array(try index.inboxes(accountIDs: ids).values)
        return try index.senders(by: grouping, mailboxes: mailboxes, matching: clause, limit: limit)
    }

    /// Addresses you exchanged mail with in any enabled account. Received
    /// mail in Trash and Junk does not count.
    public func contacts(matching text: String, limit: Int) async throws -> [MailContact] {
        try index.ensureReadable()
        let accounts = try await directory.accounts().filter(\.isEnabled)
        let mailboxes = try index.mailboxes(accountIDs: accounts.map(\.id))
        return try index.contacts(matching: text,
                                  received: mailboxes.filter { !$0.isSent && !$0.isTrashOrJunk },
                                  sent: mailboxes.filter(\.isSent), limit: limit)
    }

    // MARK: - Mutations

    /// Resolves every id to exactly one live row before anything changes.
    /// An id with no row in scope is `notFound`, one with several is
    /// `badInput`; either fails the whole call, so no mutation target is
    /// ever guessed. A nil `mutation` resolves the messages without a
    /// destination, for commands that act on a message without changing it.
    public func targets(for mutation: MailMutation?, ids: [String], account: String?,
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
            let target = MailTarget(account: owner, message: message, destination: nil)
            guard let mutation else {
                out.append(target)
                continue
            }
            if mailboxesByAccount == nil {
                mailboxesByAccount = Dictionary(grouping: try index.mailboxes(accountIDs: accounts.map(\.id)),
                                                by: \.accountID)
            }
            let accountMailboxes = mailboxesByAccount?[owner.id] ?? []
            out.append(MailTarget(account: owner, message: message, destination: try Self.destination(
                for: mutation, target: target, labels: labels[message.rowID] ?? [],
                storesLabels: Self.storesLabels(accountMailboxes) || labels[message.rowID] != nil,
                mailboxes: accountMailboxes,
                holding: copies.map(\.mailbox) + copies.flatMap { labels[$0.rowID] ?? [] })))
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

    /// Where a move or copy sends `target`, or nil for a change that stays
    /// put. `labels` are the Gmail label mailboxes the message carries, and
    /// `holding` every mailbox any copy of it is in, by row or label.
    static func destination(for mutation: MailMutation, target: MailTarget, labels: [IndexMailbox],
                            storesLabels: Bool, mailboxes: [IndexMailbox],
                            holding: [IndexMailbox]) throws -> IndexMailbox? {
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
                throw MacError(.badInput, "Message \(id) is in Gmail account '\(account)', where a mailbox is a label. Add one with: mac mail label add \(id) <label>. mac cannot remove a label, so move it in Mail.")
            }
            destination = try mailbox(named: name, in: mailboxes, account: account)
        case .delete:
            let trash = try onlyMailbox("Trash", mailboxes.filter(\.isTrash), account: account)
            // Mail's Delete on a message already in Trash erases it.
            if labels.contains(where: { $0.rowID == trash.rowID }) {
                throw MacError(.badInput, "Message \(id) is already in \(trash.path). mac never erases mail.")
            }
            destination = trash
        case .copy(let name), .addLabel(let name):
            if case .addLabel = mutation, !storesLabels {
                throw MacError(.badInput, "Message \(id) is in account '\(account)', which is not Gmail and has no labels. Copy it with: mac mail copy \(id) --to \(name)")
            }
            destination = try mailbox(named: name, in: mailboxes, account: account)
            // A copy in Trash or Junk is a delete or a junk mark with a copy
            // left behind; those have their own commands.
            if destination.isTrashOrJunk {
                throw MacError(.badInput, "\(destination.path) is the Trash or Junk mailbox of '\(account)'. Use mac mail delete or mac mail junk instead.")
            }
            // A second copy could not be told apart from the first, so the
            // result could never be verified.
            let inInbox = destination.isInbox && target.message.isInInbox
            if inInbox || holding.contains(where: { $0.rowID == destination.rowID }) {
                throw MacError(.badInput, "Message \(id) is already in \(destination.path).")
            }
        case .junk:
            let junk = try onlyMailbox("Junk", mailboxes.filter(\.isJunk), account: account)
            if target.message.mailbox.rowID == junk.rowID || labels.contains(where: { $0.rowID == junk.rowID }) {
                guard !target.message.isJunk else {
                    throw MacError(.badInput, "Message \(id) is already junk, in \(junk.path).")
                }
                return nil
            }
            destination = junk
        case .notJunk:
            guard target.message.mailbox.isJunk || labels.contains(where: \.isJunk) else {
                guard target.message.isJunk else {
                    throw MacError(.badInput, "Message \(id) is not marked junk and is not in a Junk mailbox.")
                }
                return nil
            }
            let inboxes = mailboxes.filter(\.isInbox)
            guard let inbox = inboxes.first, inboxes.count == 1 else {
                throw MacError(.notFound, "Account '\(account)' has \(inboxes.isEmpty ? "no" : "more than one") inbox, so mac cannot tell where to return the message.")
            }
            destination = inbox
        }
        guard destination.rowID != target.message.mailbox.rowID else {
            throw MacError(.badInput, "Message \(id) is already in \(destination.path).\(mutation == .delete ? " mac never erases mail." : "")")
        }
        return destination
    }

    /// The account's one Trash or Junk mailbox. Both are found by name, so
    /// several candidates are refused rather than guessed.
    static func onlyMailbox(_ kind: String, _ candidates: [IndexMailbox], account: String) throws -> IndexMailbox {
        guard let mailbox = candidates.first else {
            throw MacError(.notFound, "Account '\(account)' has no \(kind) mailbox.")
        }
        guard candidates.count == 1 else {
            throw MacError(.badInput, "Account '\(account)' has \(candidates.count) \(kind) mailboxes (\(candidates.map(\.path).joined(separator: ", "))), so mac cannot tell which one Mail uses.")
        }
        return mailbox
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
                         category: message.category?.rawValue, summary: message.summary,
                         isPriority: message.isPriority, attachments: attachments)
    }
}
