import Core
import Foundation

public struct NoteActions {
    let store: NoteStore

    public init(store: NoteStore) {
        self.store = store
    }

    static let recentlyDeleted = "Recently Deleted"

    /// What a list/search operates over after folder/account flags are resolved.
    struct Scope {
        let folderID: String?
        let accountName: String?
        let includeRecentlyDeleted: Bool
    }

    public func folders(account: String?) async throws -> [NoteFolderInfo] {
        let scope = try await resolveScope(folder: nil, account: account)
        return try await store.folders()
            .filter { $0.name != Self.recentlyDeleted }
            .filter { scope.accountName == nil || $0.account == scope.accountName }
            .sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.account.localizedCaseInsensitiveCompare($1.account) == .orderedAscending
            }
    }

    public func list(folder: String?, account: String?, limit: Int) async throws -> [NoteItem] {
        try validate(limit: limit)
        let scope = try await resolveScope(folder: folder, account: account)
        let items = try await store.notes(folderID: scope.folderID)
        return apply(scope, to: items)
            .sorted { $0.modified > $1.modified }
            .prefix(limit).map { $0 }
    }

    public func search(query: String, folder: String?, account: String?, limit: Int) async throws -> [NoteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Search query cannot be empty.")
        }
        try validate(limit: limit)
        let scope = try await resolveScope(folder: folder, account: account)
        let needle = trimmed.lowercased()
        let rows = try await store.searchRows(folderID: scope.folderID)
        let matching = rows
            .filter { $0.item.title.lowercased().contains(needle) || $0.text.lowercased().contains(needle) }
            .map(\.item)
        return apply(scope, to: matching)
            .sorted { $0.modified > $1.modified }
            .prefix(limit).map { $0 }
    }

    public func read(id: String, html: Bool) async throws -> NoteItem {
        guard let item = try await store.read(id: id, html: html) else {
            throw MacError(.notFound, "No note with id \(id). List ids with: mac notes list")
        }
        return item
    }

    public func add(title: String, body: String, folder: String?, account: String?) async throws -> NoteItem {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Note title cannot be empty.")
        }
        let scope = try await resolveScope(folder: folder, account: account)
        if folder == nil, account != nil {
            throw MacError(.badInput, "--account requires --folder when adding a note.")
        }
        return try await store.add(title: trimmed, body: body, folderID: scope.folderID)
    }

    public func append(id: String, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MacError(.badInput, "Append text cannot be empty.")
        }
        guard try await store.append(id: id, text: text) else {
            throw MacError(.notFound, "No note with id \(id). List ids with: mac notes list")
        }
    }

    public func edit(id: String, title: String?, body: String?) async throws {
        if title == nil && body == nil {
            throw MacError(.badInput, "Nothing to change. Pass --title and/or --body.")
        }
        if let title, title.trimmingCharacters(in: .whitespaces).isEmpty {
            throw MacError(.badInput, "Note title cannot be empty.")
        }
        guard try await store.edit(id: id, title: title, body: body) else {
            throw MacError(.notFound, "No note with id \(id). List ids with: mac notes list")
        }
    }

    public func delete(id: String) async throws {
        guard try await store.delete(id: id) else {
            throw MacError(.notFound, "No note with id \(id). List ids with: mac notes list")
        }
    }

    // MARK: - Internals

    func resolveScope(folder: String?, account: String?) async throws -> Scope {
        let allFolders = try await store.folders()
        var canonicalAccount: String?
        if let account {
            let names = Set(allFolders.map(\.account))
            guard let match = names.first(where: { $0.caseInsensitiveCompare(account) == .orderedSame }) else {
                throw MacError(.notFound, "No Notes account named '\(account)'. Run: mac notes folders")
            }
            canonicalAccount = match
        }
        guard let folder else {
            return Scope(folderID: nil, accountName: canonicalAccount, includeRecentlyDeleted: false)
        }
        let wantsDeleted = folder.caseInsensitiveCompare(Self.recentlyDeleted) == .orderedSame
        let candidates = allFolders.filter {
            $0.name.caseInsensitiveCompare(folder) == .orderedSame
                && (canonicalAccount == nil || $0.account == canonicalAccount)
        }
        if candidates.isEmpty {
            throw MacError(.notFound, "No folder named '\(folder)'. Run: mac notes folders")
        }
        if candidates.count > 1 {
            let accounts = candidates.map(\.account).sorted().prefix(5).joined(separator: ", ")
            throw MacError(.badInput, "Folder '\(folder)' exists in multiple accounts: \(accounts). Add --account to pick one.")
        }
        return Scope(folderID: candidates[0].id, accountName: canonicalAccount,
                     includeRecentlyDeleted: wantsDeleted)
    }

    func apply(_ scope: Scope, to items: [NoteItem]) -> [NoteItem] {
        items.filter {
            (scope.includeRecentlyDeleted || $0.folder != Self.recentlyDeleted)
                && (scope.accountName == nil || $0.account == scope.accountName)
        }
    }

    func validate(limit: Int) throws {
        guard (1...500).contains(limit) else {
            throw MacError(.badInput, "--limit must be between 1 and 500.")
        }
    }
}
