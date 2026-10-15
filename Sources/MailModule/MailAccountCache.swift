import CryptoKit
import Foundation
import SQLite3

/// The account list Mail.app last reported, kept beside a fingerprint of the
/// system account store (`~/Library/Accounts/Accounts4.sqlite`) it came from.
/// Adding, removing, renaming or toggling an account rewrites that store, so
/// a matching fingerprint means Mail would answer the same. Names always come
/// from Mail; nothing is derived from the store.
public struct MailAccountCache {
    let storePath: String
    let cachePath: String

    public init(storePath: String = NSHomeDirectory() + "/Library/Accounts/Accounts4.sqlite",
                cachePath: String = NSHomeDirectory() + "/Library/Caches/mac-cli/mail-accounts.json") {
        self.storePath = storePath
        self.cachePath = cachePath
    }

    struct Snapshot: Equatable {
        let fingerprint: String
        /// `ZACCOUNT.ZIDENTIFIER` of every row. Mail's account ids are these.
        let identifiers: Set<String>
    }

    struct StoreUnreadable: Error {}

    private struct File: Codable {
        static let currentVersion = 1
        var version = currentVersion
        let fingerprint: String
        let accounts: [MailAccount]
    }

    /// Hashes every row of `ZACCOUNT` and of the enabled-dataclass join table.
    /// Core Data numbers join tables per model version (`Z_2ENABLEDDATACLASSES`),
    /// so it is found by suffix. Throws `StoreUnreadable` for anything that
    /// stops the read: no Full Disk Access, a missing file, a changed schema.
    func snapshot() throws -> Snapshot {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(storePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw StoreUnreadable()
        }
        sqlite3_busy_timeout(db, 1000)

        var joinTables: [String] = []
        try forEachRow(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Z\\_%ENABLEDDATACLASSES' ESCAPE '\\' ORDER BY name;") { stmt in
            joinTables.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        guard !joinTables.isEmpty else { throw StoreUnreadable() }

        let statements = ["SELECT * FROM ZACCOUNT ORDER BY Z_PK;"]
            + joinTables.map { "SELECT * FROM \"\($0.replacingOccurrences(of: "\"", with: "\"\""))\" ORDER BY 1, 2;" }
        var hash = SHA256()
        for sql in statements {
            hash.update(data: Data(sql.utf8 + [0]))
            try forEachRow(db, sql) { stmt in
                for col in 0..<sqlite3_column_count(stmt) {
                    hash.update(data: Self.encode(stmt, col))
                }
                hash.update(data: Data([0x1E]))
            }
        }

        var identifiers: Set<String> = []
        try forEachRow(db, "SELECT ZIDENTIFIER FROM ZACCOUNT WHERE ZIDENTIFIER IS NOT NULL;") { stmt in
            identifiers.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return Snapshot(fingerprint: fingerprint, identifiers: identifiers)
    }

    /// The stored list when it was saved against this fingerprint. A missing,
    /// unreadable or corrupt file is a miss, never an error.
    func accounts(matching fingerprint: String) -> [MailAccount]? {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == File.currentVersion,
              file.fingerprint == fingerprint,
              !file.accounts.isEmpty else { return nil }
        return file.accounts
    }

    /// Stores Mail's list only when the store knows every account in it: an
    /// account the store lacks could be renamed without changing the
    /// fingerprint. Failing to write only costs the next run a Mail.app call.
    func save(_ accounts: [MailAccount], snapshot: Snapshot) {
        guard !accounts.isEmpty,
              Set(accounts.map(\.id)).isSubset(of: snapshot.identifiers),
              let data = try? JSONEncoder().encode(File(fingerprint: snapshot.fingerprint, accounts: accounts))
        else { return }
        let directory = (cachePath as NSString).deletingLastPathComponent
        let temporary = "\(cachePath).\(getpid()).tmp"
        guard (try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil,
              FileManager.default.createFile(atPath: temporary, contents: data,
                                             attributes: [.posixPermissions: 0o600])
        else { return }
        if rename(temporary, cachePath) != 0 {
            unlink(temporary)
        }
    }

    /// Type-tagged and length-prefixed, so no two different rows hash alike.
    private static func encode(_ stmt: OpaquePointer, _ col: Int32) -> Data {
        switch sqlite3_column_type(stmt, col) {
        case SQLITE_INTEGER:
            return Data("i\(sqlite3_column_int64(stmt, col))\u{1F}".utf8)
        case SQLITE_FLOAT:
            return Data("f\(sqlite3_column_double(stmt, col))\u{1F}".utf8)
        case SQLITE_TEXT, SQLITE_BLOB:
            let tag = sqlite3_column_type(stmt, col) == SQLITE_TEXT ? "t" : "b"
            let count = Int(sqlite3_column_bytes(stmt, col))
            var data = Data("\(tag)\(count):".utf8)
            if count > 0, let bytes = sqlite3_column_blob(stmt, col) {
                data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            }
            data.append(0x1F)
            return data
        default:
            return Data("n\u{1F}".utf8)
        }
    }

    private func forEachRow(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreUnreadable()
        }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            body(stmt)
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreUnreadable() }
    }
}
