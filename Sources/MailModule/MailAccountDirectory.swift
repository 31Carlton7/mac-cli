import Core
import Foundation

/// A Mail account as Mail.app reports it. `id` is the account segment of
/// every mailbox URL in the Envelope Index (`imap://<id>/INBOX`).
public struct MailAccount: Equatable {
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
public struct MailAccountDirectory {
    private let fetch: () async throws -> String

    public init() {
        self.init(fetch: { try await AppleScript.run(MailScripts.accountDirectory(), targetName: "Mail") })
    }

    /// `fetch` returns the `accountDirectory` script's output.
    init(fetch: @escaping () async throws -> String) {
        self.fetch = fetch
    }

    public func accounts() async throws -> [MailAccount] {
        Self.accounts(from: try await fetch())
    }

    /// Case-insensitive, like 0.6's `--account`, and returns Mail's spelling.
    public func account(named name: String) async throws -> MailAccount {
        guard let match = try await accounts().first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw MacError(.notFound, "No mail account named '\(name)'. Run: mac mail accounts")
        }
        return match
    }

    static func accounts(from output: String) -> [MailAccount] {
        AppleScript.parseRecords(output).compactMap { fields in
            guard fields.count >= 3, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return MailAccount(id: fields[0], name: fields[1], isEnabled: fields[2] == "1")
        }
    }
}
