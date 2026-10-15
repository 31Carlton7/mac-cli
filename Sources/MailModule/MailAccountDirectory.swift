import Core
import Foundation

/// A Mail account as Mail.app reports it. `id` is the account segment of
/// every mailbox URL in the Envelope Index (`imap://<id>/INBOX`).
public struct MailAccount: Equatable, Codable {
    public let id: String
    public let name: String
    public let isEnabled: Bool

    public init(id: String, name: String, isEnabled: Bool) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
    }
}

/// Account name <-> id, from one Mail.app call. Mail's own order is kept.
/// With a cache, that call is skipped while the system account store is
/// unchanged; a store that cannot be read means asking Mail every time.
public struct MailAccountDirectory {
    private let fetch: () async throws -> String
    let cache: MailAccountCache?

    /// `cache: nil` asks Mail.app on every call.
    public init(cache: MailAccountCache? = MailAccountCache()) {
        self.init(cache: cache, fetch: { try await AppleScript.run(MailScripts.accountDirectory(), targetName: "Mail") })
    }

    /// `fetch` returns the `accountDirectory` script's output.
    init(cache: MailAccountCache? = nil, fetch: @escaping () async throws -> String) {
        self.cache = cache
        self.fetch = fetch
    }

    public func accounts() async throws -> [MailAccount] {
        try await load().accounts
    }

    /// Case-insensitive, like 0.6's `--account`, and returns Mail's spelling.
    /// A name the cached list lacks is asked of Mail.app before it is
    /// reported missing.
    public func account(named name: String) async throws -> MailAccount {
        try Self.account(named: name, in: try await accounts(knowing: [name]))
    }

    /// Every account. When the cached list lacks one of `names`, Mail.app
    /// is asked again first, so no name is reported missing only because
    /// the cache predates its account.
    func accounts(knowing names: [String]) async throws -> [MailAccount] {
        let loaded = try await load()
        guard let snapshot = loaded.cachedAgainst,
              names.contains(where: { Self.match($0, in: loaded.accounts) == nil }) else {
            return loaded.accounts
        }
        return try await refresh(snapshot)
    }

    static func account(named name: String, in accounts: [MailAccount]) throws -> MailAccount {
        guard let match = match(name, in: accounts) else {
            throw MacError(.notFound, "No mail account named '\(name)'. Run: mac mail accounts")
        }
        return match
    }

    /// `cachedAgainst` is set only when the list came from the cache.
    private func load() async throws -> (accounts: [MailAccount], cachedAgainst: MailAccountCache.Snapshot?) {
        guard let cache, let snapshot = try? cache.snapshot() else {
            return (try await refresh(nil), nil)
        }
        if let stored = cache.accounts(matching: snapshot.fingerprint) {
            return (stored, snapshot)
        }
        return (try await refresh(snapshot), nil)
    }

    /// Asks Mail.app, and stores the answer against the snapshot taken
    /// before the call. A change landing in between leaves a stale
    /// fingerprint, which only costs the next run another call.
    private func refresh(_ snapshot: MailAccountCache.Snapshot?) async throws -> [MailAccount] {
        let accounts = Self.accounts(from: try await fetch())
        if let cache, let snapshot {
            cache.save(accounts, snapshot: snapshot)
        }
        return accounts
    }

    private static func match(_ name: String, in accounts: [MailAccount]) -> MailAccount? {
        accounts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func accounts(from output: String) -> [MailAccount] {
        AppleScript.parseRecords(output).compactMap { fields in
            guard fields.count >= 3, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return MailAccount(id: fields[0], name: fields[1], isEnabled: fields[2] == "1")
        }
    }
}
