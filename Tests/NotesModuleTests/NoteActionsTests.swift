import XCTest
import Core
@testable import NotesModule

final class MockNoteStore: NoteStore {
    var accessGranted = true
    var storedFolders: [NoteFolderInfo] = []
    var storedNotes: [NoteItem] = []
    var bodies: [String: String] = [:]      // note id -> plaintext
    var appended: [(id: String, text: String)] = []
    var edited: [(id: String, title: String?, body: String?)] = []
    var deletedIDs: [String] = []
    var addedDrafts: [(title: String, body: String, folderID: String?)] = []

    private func gate() throws {
        if !accessGranted {
            throw MacError(.permissionDenied, "Notes automation not granted. Run: mac doctor")
        }
    }

    func folders() async throws -> [NoteFolderInfo] {
        try gate()
        return storedFolders
    }

    func notes(folderID: String?) async throws -> [NoteItem] {
        try gate()
        guard let folderID else { return storedNotes }
        guard let folder = storedFolders.first(where: { $0.id == folderID }) else { return [] }
        return storedNotes.filter { $0.folder == folder.name && $0.account == folder.account }
    }

    func searchRows(folderID: String?) async throws -> [NoteSearchRow] {
        try await notes(folderID: folderID).map { NoteSearchRow(item: $0, text: bodies[$0.id] ?? "") }
    }

    func read(id: String, html: Bool) async throws -> NoteItem? {
        try gate()
        guard let item = storedNotes.first(where: { $0.id == id }) else { return nil }
        return NoteItem(id: item.id, title: item.title, folder: item.folder, account: item.account,
                        created: item.created, modified: item.modified,
                        body: html ? "<div>\(bodies[item.id] ?? "")</div>" : bodies[item.id] ?? "")
    }

    func add(title: String, body: String, folderID: String?) async throws -> NoteItem {
        try gate()
        addedDrafts.append((title, body, folderID))
        return NoteItem(id: "new-1", title: title, folder: "Notes", account: "iCloud",
                        created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0),
                        body: nil)
    }

    func append(id: String, text: String) async throws -> Bool {
        try gate()
        guard storedNotes.contains(where: { $0.id == id }) else { return false }
        appended.append((id, text))
        return true
    }

    func edit(id: String, title: String?, body: String?) async throws -> Bool {
        try gate()
        guard storedNotes.contains(where: { $0.id == id }) else { return false }
        edited.append((id, title, body))
        return true
    }

    func delete(id: String) async throws -> Bool {
        try gate()
        guard storedNotes.contains(where: { $0.id == id }) else { return false }
        deletedIDs.append(id)
        return true
    }
}

final class NoteActionsTests: XCTestCase {
    var store = MockNoteStore()
    lazy var actions = NoteActions(store: store)
    let base = Date(timeIntervalSince1970: 1_787_824_800)

    func folder(_ id: String, _ name: String, _ account: String) -> NoteFolderInfo {
        NoteFolderInfo(id: id, name: name, account: account, noteCount: 0)
    }

    func note(_ id: String, title: String = "t", folder: String = "Notes",
              account: String = "iCloud", offset: TimeInterval = 0) -> NoteItem {
        NoteItem(id: id, title: title, folder: folder, account: account,
                 created: base, modified: base.addingTimeInterval(offset), body: nil)
    }

    override func setUp() {
        super.setUp()
        store = MockNoteStore()
        actions = NoteActions(store: store)
        store.storedFolders = [
            folder("f-icloud-notes", "Notes", "iCloud"),
            folder("f-work-notes", "Notes", "Work"),
            folder("f-ideas", "Ideas", "iCloud"),
            folder("f-rd", "Recently Deleted", "iCloud"),
        ]
    }

    func testAmbiguousFolderThrowsBadInputNamingAccounts() async {
        do {
            _ = try await actions.list(folder: "Notes", account: nil, limit: 20)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("iCloud"))
            XCTAssertTrue(error.message.contains("Work"))
        } catch { XCTFail("wrong error type") }
    }

    func testAccountDisambiguatesFolder() async throws {
        store.storedNotes = [note("n1", folder: "Notes", account: "Work")]
        let items = try await actions.list(folder: "notes", account: "work", limit: 20)
        XCTAssertEqual(items.map(\.id), ["n1"])
    }

    func testUniqueFolderResolvesWithoutAccount() async throws {
        store.storedNotes = [note("n1", folder: "Ideas", account: "iCloud")]
        let items = try await actions.list(folder: "Ideas", account: nil, limit: 20)
        XCTAssertEqual(items.map(\.id), ["n1"])
    }

    func testUnknownFolderThrowsNotFound() async {
        do {
            _ = try await actions.list(folder: "Bogus", account: nil, limit: 20)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testUnknownAccountThrowsNotFound() async {
        do {
            _ = try await actions.list(folder: nil, account: "Bogus", limit: 20)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testRecentlyDeletedExcludedByDefault() async throws {
        store.storedNotes = [note("live"), note("gone", folder: "Recently Deleted")]
        let items = try await actions.list(folder: nil, account: nil, limit: 20)
        XCTAssertEqual(items.map(\.id), ["live"])
    }

    func testRecentlyDeletedIncludedWhenExplicit() async throws {
        store.storedNotes = [note("gone", folder: "Recently Deleted")]
        let items = try await actions.list(folder: "Recently Deleted", account: nil, limit: 20)
        XCTAssertEqual(items.map(\.id), ["gone"])
    }

    func testAccountOnlyFilters() async throws {
        store.storedNotes = [note("a", account: "iCloud"), note("b", folder: "Notes", account: "Work")]
        let items = try await actions.list(folder: nil, account: "iCloud", limit: 20)
        XCTAssertEqual(items.map(\.id), ["a"])
    }

    func testListSortsNewestFirstAndTruncates() async throws {
        store.storedNotes = [note("old", offset: 0), note("new", offset: 100), note("mid", offset: 50)]
        let items = try await actions.list(folder: nil, account: nil, limit: 2)
        XCTAssertEqual(items.map(\.id), ["new", "mid"])
    }

    func testSearchMatchesTitleAndBodyCaseInsensitively() async throws {
        store.storedNotes = [note("byTitle", title: "Brunch Paybacks"), note("byBody", title: "x")]
        store.bodies = ["byBody": "remember the BRUNCH money"]
        let items = try await actions.search(query: "brunch", folder: nil, account: nil, limit: 20)
        XCTAssertEqual(Set(items.map(\.id)), ["byTitle", "byBody"])
    }

    func testSearchEmptyQueryThrowsBadInput() async {
        do {
            _ = try await actions.search(query: "  ", folder: nil, account: nil, limit: 20)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testReadUnknownIDThrowsNotFound() async {
        do {
            _ = try await actions.read(id: "nope", html: false)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testAddEmptyTitleThrowsBadInput() async {
        do {
            _ = try await actions.add(title: "  ", body: "b", folder: nil, account: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testAppendEmptyTextThrowsBadInput() async {
        do {
            try await actions.append(id: "n1", text: " ")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testEditWithNoFlagsThrowsBadInput() async {
        do {
            try await actions.edit(id: "n1", title: nil, body: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testDeleteUnknownIDThrowsNotFound() async {
        do {
            try await actions.delete(id: "nope")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testFoldersExcludesRecentlyDeletedAndSorts() async throws {
        let folders = try await actions.folders(account: nil)
        XCTAssertEqual(folders.map(\.id), ["f-ideas", "f-icloud-notes", "f-work-notes"])
    }

    func testPermissionDeniedPropagates() async {
        store.accessGranted = false
        do {
            _ = try await actions.list(folder: nil, account: nil, limit: 5)
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }
}
