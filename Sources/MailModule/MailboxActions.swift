import Core
import Foundation

/// The outcome of one mailbox command, or with `dryRun` what it would do.
public struct MailboxChange: Codable, Equatable, HumanRenderable {
    public let action: String
    public let account: String
    public let path: String
    /// The new path, for a rename.
    public let to: String?
    public let dryRun: Bool

    public init(action: String, account: String, path: String, to: String? = nil, dryRun: Bool) {
        self.action = action
        self.account = account
        self.path = path
        self.to = to
        self.dryRun = dryRun
    }

    public var humanLine: String {
        let target = to.map { "\(path) -> \($0)" } ?? path
        let verb = dryRun ? "would \(action)" : "\(action)d"
        return "\(verb) mailbox \(target) in \(account)"
    }
}

public struct MailboxActions {
    let store: MailboxStore

    public init(store: MailboxStore) {
        self.store = store
    }

    /// Names Mail and the common providers give an account's system mailboxes,
    /// in English and the localizations Mail ships most. Deleting or renaming
    /// one breaks the account, so both are refused. Compared case-insensitively
    /// against the whole path.
    static let specialMailboxNames: Set<String> = [
        "inbox", "outbox", "sent", "sent mail", "sent items", "sent messages",
        "drafts", "trash", "bin", "deleted items", "deleted messages",
        "junk", "junk email", "junk e-mail", "spam", "bulk mail",
        "archive", "all mail", "important", "starred", "notes",
        "conversation history", "journal", "tasks", "calendar", "contacts", "sync issues",
        "posteingang", "gesendet", "gesendete elemente", "entwürfe", "papierkorb",
        "gelöschte elemente", "spam-e-mail", "archiv",
        "boîte de réception", "envoyés", "éléments envoyés", "brouillons", "corbeille",
        "éléments supprimés", "courrier indésirable", "archives",
        "bandeja de entrada", "enviados", "elementos enviados", "borradores", "papelera",
        "elementos eliminados", "correo no deseado", "archivo",
    ]

    static func isSpecial(_ path: String) -> Bool {
        let lowered = path.lowercased()
        if specialMailboxNames.contains(lowered) { return true }
        // Gmail's system folders, whatever Mail chooses to call them.
        return lowered.hasPrefix("[gmail]/") || lowered.hasPrefix("[google mail]/")
            || lowered == "[gmail]" || lowered == "[google mail]"
    }

    public func create(name: String, parent: String?, account: String,
                       dryRun: Bool) async throws -> MailboxChange {
        let leaf = try Self.validName(name, flag: "name")
        let parentPath = try parent.map { try Self.validPath($0, flag: "--parent") }
        let tree = try await tree(account: account)
        let resolvedParent = try parentPath.map { try Self.resolve($0, in: tree) }
        let path = resolvedParent.map { "\($0)/\(leaf)" } ?? leaf
        if let clash = Self.existing(path, in: tree) {
            throw MacError(.badInput, "A mailbox named '\(clash)' already exists in \(tree.account).")
        }
        let change = MailboxChange(action: "create", account: tree.account, path: path, dryRun: dryRun)
        if dryRun { return change }
        let result = try await store.createMailbox(account: tree.account, parent: resolvedParent, path: path)
        try Self.check(result, account: tree.account, path: path, parent: resolvedParent)
        return change
    }

    public func rename(path: String, to newName: String, account: String,
                       dryRun: Bool) async throws -> MailboxChange {
        let requested = try Self.validPath(path, flag: "path")
        let leaf = try Self.validName(newName, flag: "--to")
        let tree = try await tree(account: account)
        let current = try Self.resolve(requested, in: tree)
        if Self.isSpecial(current) {
            throw MacError(.badInput, "'\(current)' is a system mailbox of \(tree.account); it cannot be renamed.")
        }
        let parentPath = current.split(separator: "/").dropLast().joined(separator: "/")
        let newPath = parentPath.isEmpty ? leaf : "\(parentPath)/\(leaf)"
        if newPath == current {
            throw MacError(.badInput, "Mailbox '\(current)' is already named '\(leaf)'.")
        }
        if let clash = Self.existing(newPath, in: tree), clash != current {
            throw MacError(.badInput, "A mailbox named '\(clash)' already exists in \(tree.account).")
        }
        let change = MailboxChange(action: "rename", account: tree.account, path: current,
                                   to: newPath, dryRun: dryRun)
        if dryRun { return change }
        let result = try await store.renameMailbox(account: tree.account, path: current,
                                                   newName: leaf, newPath: newPath)
        try Self.check(result, account: tree.account, path: current, parent: nil, clash: newPath)
        return change
    }

    public func delete(path: String, account: String, dryRun: Bool) async throws -> MailboxChange {
        let requested = try Self.validPath(path, flag: "path")
        let tree = try await tree(account: account)
        let current = try Self.resolve(requested, in: tree)
        if Self.isSpecial(current) {
            throw MacError(.badInput, "'\(current)' is a system mailbox of \(tree.account); it cannot be deleted.")
        }
        let children = tree.mailboxes.filter { $0.path.hasPrefix(current + "/") }.count
        if children > 0 {
            throw Self.hasChildren(current, children)
        }
        let count = tree.mailboxes.first { $0.path == current }?.messageCount ?? -1
        if count < 0 {
            throw MacError(.badInput, "Mail would not count the messages in '\(current)', so it is not deleted.")
        }
        if count > 0 {
            throw Self.notEmpty(current, count)
        }
        let change = MailboxChange(action: "delete", account: tree.account, path: current, dryRun: dryRun)
        if dryRun { return change }
        let result = try await store.deleteMailbox(account: tree.account, path: current)
        try Self.check(result, account: tree.account, path: current, parent: nil)
        return change
    }

    // MARK: - Resolution

    private func tree(account: String) async throws -> MailboxTree {
        let name = account.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw MacError(.badInput, "--account cannot be empty.")
        }
        guard let tree = try await store.mailboxTree(account: name) else {
            throw Self.noAccount(name)
        }
        return tree
    }

    /// Mail's own spelling of `path`. An exact match wins; otherwise one
    /// case-insensitive match is accepted and several are refused rather than guessed.
    static func resolve(_ path: String, in tree: MailboxTree) throws -> String {
        if tree.mailboxes.contains(where: { $0.path == path }) { return path }
        let matches = tree.mailboxes.map(\.path).filter { $0.caseInsensitiveCompare(path) == .orderedSame }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw MacError(.notFound, "No mailbox '\(path)' in \(tree.account).")
        default:
            throw MacError(.badInput, "'\(path)' matches several mailboxes in \(tree.account): \(matches.joined(separator: ", ")). Pass the exact spelling.")
        }
    }

    /// The existing path `path` would collide with. Mail treats mailbox names
    /// case-insensitively on most servers, so a case-only difference collides.
    static func existing(_ path: String, in tree: MailboxTree) -> String? {
        tree.mailboxes.map(\.path).first { $0.caseInsensitiveCompare(path) == .orderedSame }
    }

    // MARK: - Validation

    /// One path component: no `/` (nest with `--parent`), no control characters.
    static func validName(_ raw: String, flag: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw MacError(.badInput, "Mailbox \(flag) cannot be empty.")
        }
        guard !name.contains("/") else {
            throw MacError(.badInput, "Mailbox \(flag) '\(name)' cannot contain '/'. Use --parent to nest a mailbox.")
        }
        guard name != ".", name != ".." else {
            throw MacError(.badInput, "Mailbox \(flag) cannot be '\(name)'.")
        }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MacError(.badInput, "Mailbox \(flag) cannot contain control characters.")
        }
        return name
    }

    /// A slash-separated path; outer slashes are dropped, empty components refused.
    static func validPath(_ raw: String, flag: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(["/"]))
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Mailbox \(flag) cannot be empty.")
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw MacError(.badInput, "Mailbox \(flag) '\(raw)' has an empty component.")
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MacError(.badInput, "Mailbox \(flag) cannot contain control characters.")
        }
        return trimmed
    }

    // MARK: - Script results

    /// Maps a mutation script's answer onto the CLI's errors. The script checks
    /// again right before it acts, so a refusal here means the mailbox changed
    /// between the lookup and the mutation.
    static func check(_ result: MailboxScriptResult, account: String, path: String,
                      parent: String?, clash: String? = nil) throws {
        switch result {
        case .ok:
            return
        case .noAccount:
            throw noAccount(account)
        case .noMailbox:
            throw MacError(.notFound, "No mailbox '\(path)' in \(account).")
        case .noParent:
            throw MacError(.notFound, "No mailbox '\(parent ?? "")' in \(account).")
        case .exists:
            throw MacError(.badInput, "A mailbox named '\(clash ?? path)' already exists in \(account).")
        case .hasChildren(let n):
            throw hasChildren(path, n)
        case .notEmpty(let n):
            throw notEmpty(path, n)
        case .unverified:
            throw NSError(domain: "Mail", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Mail accepted the change to '\(path)' in \(account) but it is not visible afterwards. Check Mail before retrying.",
            ])
        }
    }

    static func noAccount(_ name: String) -> MacError {
        MacError(.notFound, "No mail account named '\(name)'. Run: mac mail accounts")
    }

    static func hasChildren(_ path: String, _ n: Int) -> MacError {
        MacError(.badInput, "Mailbox '\(path)' has \(n) child mailbox\(n == 1 ? "" : "es"); delete or move them first.")
    }

    static func notEmpty(_ path: String, _ n: Int) -> MacError {
        MacError(.badInput, "Mailbox '\(path)' still holds \(n) message\(n == 1 ? "" : "s"); move or delete them first.")
    }
}
