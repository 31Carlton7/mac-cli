import Core
import Foundation

public struct ShortcutActions {
    let store: ShortcutStore

    public init(store: ShortcutStore) {
        self.store = store
    }

    /// Sorted localizedCaseInsensitive by name, per the repo's list-ordering convention.
    public func list() async throws -> [ShortcutInfo] {
        let all = try await store.list()
        return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `isID` bypasses name resolution entirely and runs the id directly (even if it
    /// doesn't match anything list() would return — the store is the source of truth).
    /// Otherwise resolves nameOrID as an exact case-insensitive name against list():
    /// 0 matches -> notFound, >1 matches -> badInput naming sorted capped-5 candidates.
    public func run(nameOrID: String, input: String?, isID: Bool) async throws -> String {
        if isID {
            return try await store.run(id: nameOrID, input: input)
        }
        let all = try await list()
        let matches = all.filter { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
        if matches.isEmpty {
            throw MacError(.notFound, "No shortcut named '\(nameOrID)'. Run: mac shortcuts list")
        }
        if matches.count > 1 {
            // Sort name-then-id before capping so the candidate list is deterministic
            // regardless of store order (repo-wide "sorted capped-5" convention).
            // Ordering and tie-break equality both use caseInsensitiveCompare (the
            // same comparator the exact-match filter above uses) so the two checks
            // can't disagree on what counts as "the same name".
            let sorted = matches.sorted {
                $0.name.caseInsensitiveCompare($1.name) == .orderedAscending
                    || ($0.name.caseInsensitiveCompare($1.name) == .orderedSame && $0.id < $1.id)
            }
            let candidates = sorted.prefix(5).map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
            throw MacError(.badInput, "Multiple shortcuts named '\(nameOrID)': \(candidates). Use --id with the id from: mac shortcuts list")
        }
        return try await store.run(id: matches[0].id, input: input)
    }
}
