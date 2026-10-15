import XCTest
import SQLite3
import Core
@testable import MailModule

/// Builds a system account store with the Core Data layout of
/// `~/Library/Accounts/Accounts4.sqlite`. The join table's numbers are
/// parameters because Core Data renumbers them per model version.
enum AccountStoreFixture {
    static func schema(joinTable: String = "Z_2ENABLEDDATACLASSES") -> String {
        """
        CREATE TABLE ZACCOUNT ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZACTIVE INTEGER,
            ZAUTHENTICATED INTEGER, ZSUPPORTSAUTHENTICATION INTEGER, ZVISIBLE INTEGER, ZWARMINGUP INTEGER,
            ZACCOUNTTYPE INTEGER, ZPARENTACCOUNT INTEGER, ZDATE TIMESTAMP,
            ZLASTCREDENTIALRENEWALREJECTIONDATE TIMESTAMP, ZACCOUNTDESCRIPTION VARCHAR,
            ZAUTHENTICATIONTYPE VARCHAR, ZCREDENTIALTYPE VARCHAR, ZIDENTIFIER VARCHAR,
            ZMODIFICATIONID VARCHAR, ZOWNINGBUNDLEID VARCHAR, ZUSERNAME VARCHAR, ZDATACLASSPROPERTIES BLOB );
        CREATE INDEX ZACCOUNT_ZACCOUNTTYPE_INDEX ON ZACCOUNT (ZACCOUNTTYPE);
        CREATE TABLE ZDATACLASS ( Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZNAME BLOB , ZENUMVALUE INTEGER);
        CREATE TABLE \(joinTable) ( Z_2ENABLEDACCOUNTS INTEGER, Z_7ENABLEDDATACLASSES INTEGER,
            PRIMARY KEY (Z_2ENABLEDACCOUNTS, Z_7ENABLEDDATACLASSES) );
        """
    }

    /// One row per fixture Mail account, plus a non-Mail account (`CAL`).
    /// Mail is dataclass 1; `OLD` has it switched off.
    static let rows = """
    INSERT INTO ZDATACLASS (Z_PK, Z_ENT, Z_OPT, ZNAME) VALUES (1, 7, 1, 'com.apple.Dataclass.Mail'), (2, 7, 1, 'com.apple.Dataclass.Calendars');
    INSERT INTO ZACCOUNT (Z_PK, Z_ENT, Z_OPT, ZACTIVE, ZACCOUNTDESCRIPTION, ZIDENTIFIER, ZUSERNAME, ZDATACLASSPROPERTIES) VALUES
        (1, 2, 3, 1, 'Personal', 'GM', 'me@example.com', X'0102'),
        (2, 2, 3, 1, 'Work', 'EX', 'me@example.org', NULL),
        (3, 2, 3, 1, 'Home', 'IM', 'me@example.net', NULL),
        (4, 2, 3, 1, 'Old', 'OLD', 'old@example.com', NULL),
        (5, 2, 3, 1, 'Calendar', 'CAL', 'me@example.com', NULL);
    INSERT INTO Z_2ENABLEDDATACLASSES VALUES (1, 1), (2, 1), (3, 1), (5, 2);
    """

    /// Writes a store and returns its path.
    static func make(schema: String = schema(), rows: String = rows) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-accounts-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Accounts4.sqlite").path
        exec(path, schema + rows)
        return path
    }

    static func exec(_ path: String, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            preconditionFailure("fixture SQL failed: \(String(cString: error!))")
        }
    }
}

final class MailAccountCacheTests: XCTestCase {
    let mail = FakeDirectory()
    lazy var storePath = AccountStoreFixture.make()
    lazy var cachePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("mac-cli-cache-\(UUID().uuidString)/mac-cli/mail-accounts.json").path
    lazy var cache = MailAccountCache(storePath: storePath, cachePath: cachePath)

    func directory(cache: MailAccountCache?) -> MailAccountDirectory {
        MailAccountDirectory(cache: cache, fetch: { [mail] in
            mail.calls += 1
            return mail.output
        })
    }

    var cached: MailAccountDirectory { directory(cache: cache) }

    func storedFile() -> String? {
        FileManager.default.contents(atPath: cachePath).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Hit and miss

    func testSecondReadIsAnsweredFromTheCacheWithoutMail() async throws {
        let first = try await cached.accounts()
        let second = try await cached.accounts()
        XCTAssertEqual(first, EnvelopeIndexFixture.accounts)
        XCTAssertEqual(second, first, "Mail's order and enabled flags survive the round trip")
        XCTAssertEqual(mail.calls, 1)
    }

    func testCacheFileIsPrivateToTheUser() async throws {
        _ = try await cached.accounts()
        let attributes = try FileManager.default.attributesOfItem(atPath: cachePath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let parent = (cachePath as NSString).deletingLastPathComponent
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: parent)
        XCTAssertEqual((parentAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testFingerprintIsStableWhileTheStoreIsUnchanged() throws {
        XCTAssertEqual(try cache.snapshot(), try cache.snapshot())
    }

    func testRenamingAnAccountInTheStoreAsksMailAgain() async throws {
        _ = try await cached.accounts()
        AccountStoreFixture.exec(storePath, "UPDATE ZACCOUNT SET ZACCOUNTDESCRIPTION = 'Job', Z_OPT = 4 WHERE ZIDENTIFIER = 'EX';")
        mail.output = EnvelopeIndexFixture.directoryOutput([
            MailAccount(id: "GM", name: "Personal", isEnabled: true),
            MailAccount(id: "EX", name: "Job", isEnabled: true),
        ])
        let names = try await cached.accounts().map(\.name)
        XCTAssertEqual(names, ["Personal", "Job"])
        XCTAssertEqual(mail.calls, 2)
        _ = try await cached.accounts()
        XCTAssertEqual(mail.calls, 2, "the new answer was stored")
    }

    func testTogglingMailForAnAccountAsksMailAgain() async throws {
        _ = try await cached.accounts()
        AccountStoreFixture.exec(storePath, "DELETE FROM Z_2ENABLEDDATACLASSES WHERE Z_2ENABLEDACCOUNTS = 3;")
        _ = try await cached.accounts()
        XCTAssertEqual(mail.calls, 2)
    }

    func testTheJoinTableIsFoundWhateverCoreDataNumberedIt() async throws {
        storePath = AccountStoreFixture.make(
            schema: AccountStoreFixture.schema(joinTable: "Z_3ENABLEDDATACLASSES"),
            rows: AccountStoreFixture.rows.replacingOccurrences(of: "Z_2ENABLEDDATACLASSES", with: "Z_3ENABLEDDATACLASSES"))
        cache = MailAccountCache(storePath: storePath, cachePath: cachePath)
        _ = try await cached.accounts()
        _ = try await cached.accounts()
        XCTAssertEqual(mail.calls, 1)
    }

    // MARK: - Never not-found from the cache

    func testANameTheCacheLacksAsksMailOnce() async throws {
        _ = try await cached.accounts()
        mail.output = EnvelopeIndexFixture.directoryOutput(
            EnvelopeIndexFixture.accounts + [MailAccount(id: "CAL", name: "New", isEnabled: true)])
        let account = try await cached.account(named: "new")
        XCTAssertEqual(account, MailAccount(id: "CAL", name: "New", isEnabled: true))
        XCTAssertEqual(mail.calls, 2)
        _ = try await cached.account(named: "New")
        XCTAssertEqual(mail.calls, 2, "the fresh list replaced the cached one")
    }

    func testAnUnknownNameIsNotFoundOnlyAfterAskingMail() async throws {
        _ = try await cached.accounts()
        do {
            _ = try await cached.account(named: "Bogus")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        }
        XCTAssertEqual(mail.calls, 2, "one re-ask, no more")
    }

    func testAKnownNameIsAnsweredFromTheCache() async throws {
        _ = try await cached.accounts()
        let account = try await cached.account(named: "work")
        XCTAssertEqual(account.id, "EX")
        XCTAssertEqual(mail.calls, 1)
    }

    // MARK: - Bad cache, bad store

    func testACorruptCacheFileIsAMissAndIsRewritten() async throws {
        _ = try await cached.accounts()
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: cachePath))
        let accounts = try await cached.accounts()
        XCTAssertEqual(accounts, EnvelopeIndexFixture.accounts)
        XCTAssertEqual(mail.calls, 2)
        _ = try await cached.accounts()
        XCTAssertEqual(mail.calls, 2, "rewritten as a valid file")
    }

    func testAnUnreadableStoreAsksMailEveryTimeAndWritesNothing() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storePath)
        addTeardownBlock { [storePath] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storePath)
        }
        let accounts = try await cached.accounts()
        _ = try await cached.accounts()
        XCTAssertEqual(accounts, EnvelopeIndexFixture.accounts)
        XCTAssertEqual(mail.calls, 2)
        XCTAssertNil(storedFile())
    }

    func testAStoreWithoutTheJoinTableAsksMailEveryTime() async throws {
        storePath = AccountStoreFixture.make(
            schema: AccountStoreFixture.schema(joinTable: "Z_2PROVISIONEDDATACLASSES"),
            rows: AccountStoreFixture.rows.replacingOccurrences(of: "Z_2ENABLEDDATACLASSES", with: "Z_2PROVISIONEDDATACLASSES"))
        cache = MailAccountCache(storePath: storePath, cachePath: cachePath)
        _ = try await cached.accounts()
        _ = try await cached.accounts()
        XCTAssertEqual(mail.calls, 2)
        XCTAssertThrowsError(try cache.snapshot())
    }

    func testAMissingStoreAsksMailEveryTime() async throws {
        cache = MailAccountCache(storePath: storePath + "-missing", cachePath: cachePath)
        _ = try await cached.accounts()
        _ = try await cached.accounts()
        XCTAssertEqual(mail.calls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storePath + "-missing"), "read-only open creates nothing")
    }

    /// The fingerprint cannot see a rename of an account the store does not hold.
    func testAMailAccountTheStoreLacksIsNeverCached() async throws {
        mail.output = EnvelopeIndexFixture.directoryOutput(
            EnvelopeIndexFixture.accounts + [MailAccount(id: "LOCAL", name: "Local", isEnabled: true)])
        _ = try await cached.accounts()
        _ = try await cached.accounts()
        XCTAssertEqual(mail.calls, 2)
        XCTAssertNil(storedFile())
    }

    func testAMailFailureIsThrownAndNotCached() async throws {
        let failing = MailAccountDirectory(cache: cache, fetch: {
            throw MacError(.permissionDenied, "Mail automation not granted.")
        })
        do {
            _ = try await failing.accounts()
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        }
        XCTAssertNil(storedFile())
    }

    // MARK: - --no-cache

    func testNoCacheAsksMailEveryTimeAndLeavesTheFileAlone() async throws {
        _ = try await cached.accounts()
        let before = storedFile()
        let uncached = directory(cache: nil)
        _ = try await uncached.accounts()
        _ = try await uncached.account(named: "Work")
        XCTAssertEqual(mail.calls, 3)
        XCTAssertEqual(storedFile(), before)
    }

    func testNoCacheFlagParsesOnEveryReadCommand() throws {
        for arguments in [["unread", "--no-cache"], ["search", "invoice", "--no-cache"],
                          ["read", "<m1@x>", "--no-cache"], ["accounts", "--no-cache"]] {
            XCTAssertNoThrow(try MailCommand.parseAsRoot(arguments), arguments.joined(separator: " "))
        }
        let unread = try XCTUnwrap(try MailCommand.parseAsRoot(["unread", "--no-cache"]) as? MailCommand.Unread)
        XCTAssertNil(unread.accountCache.index.directory.cache)
        let cachedUnread = try XCTUnwrap(try MailCommand.parseAsRoot(["unread"]) as? MailCommand.Unread)
        XCTAssertNotNil(cachedUnread.accountCache.index.directory.cache)
    }

    func testMutationsNeverUseTheCache() {
        XCTAssertNil(MailCommand.uncachedIndex.directory.cache)
        XCTAssertThrowsError(try MailCommand.parseAsRoot(["mark-read", "<m1@x>", "--no-cache"]))
    }

    // MARK: - Index reads

    func testWarmCacheIndexReadsMakeNoMailCall() async throws {
        let index = IndexMailStore(index: EnvelopeIndex(path: EnvelopeIndexFixture.make()), directory: cached)
        _ = try await index.unread(account: nil, limit: 20)
        XCTAssertEqual(mail.calls, 1)
        let unread = try await index.unread(account: nil, limit: 20)
        let found = try await index.search(query: "invoice", limit: 20)
        let work = try await index.unread(account: "Work", limit: 20)
        XCTAssertEqual(unread.count, 4)
        XCTAssertEqual(found.count, 5)
        XCTAssertFalse(work.isEmpty)
        XCTAssertEqual(mail.calls, 1)
    }
}
