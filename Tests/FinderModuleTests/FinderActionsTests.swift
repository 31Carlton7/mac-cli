import XCTest
import Core
@testable import FinderModule

final class MockFinderStore: FinderStore {
    var storedSelection: [FinderItem] = []
    var storedDisks: [DiskInfo] = []
    var vanishedDiskNames: Set<String> = []   // eject(name:) returns false for these

    var revealedPaths: [String] = []
    var openedPaths: [String] = []
    var trashedPaths: [String] = []
    var ejectedNames: [String] = []

    func selection() async throws -> [FinderItem] { storedSelection }

    func reveal(path: String) async throws { revealedPaths.append(path) }
    func open(path: String) async throws { openedPaths.append(path) }
    func trash(path: String) async throws { trashedPaths.append(path) }

    func disks() async throws -> [DiskInfo] { storedDisks }

    func eject(name: String) async throws -> Bool {
        if vanishedDiskNames.contains(name) { return false }
        ejectedNames.append(name)
        return true
    }
}

final class FinderActionsTests: XCTestCase {
    var store = MockFinderStore()
    lazy var actions = FinderActions(store: store)

    let originalCWD = FileManager.default.currentDirectoryPath
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        store = MockFinderStore()
        actions = FinderActions(store: store)
        store.storedDisks = [
            DiskInfo(name: "Macintosh HD", capacityBytes: 500_000_000_000, freeBytes: 100_000_000_000, ejectable: false),
            DiskInfo(name: "Backup Drive", capacityBytes: 2_000_000_000_000, freeBytes: 500_000_000_000, ejectable: true),
        ]

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-cli-finder-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        FileManager.default.changeCurrentDirectoryPath(originalCWD)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - selection / disks passthrough

    func testSelectionPassthrough() async throws {
        store.storedSelection = [FinderItem(path: "/tmp/a.txt", name: "a.txt", kind: "Plain Text Document")]
        let result = try await actions.selection()
        XCTAssertEqual(result, store.storedSelection)
    }

    func testDisksPassthrough() async throws {
        let result = try await actions.disks()
        XCTAssertEqual(result, store.storedDisks)
    }

    // MARK: - resolve(path:)

    func testResolveEmptyPathThrowsBadInput() async {
        do {
            try await actions.reveal(path: "   ")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testResolveNonexistentPathThrowsNotFound() async {
        do {
            try await actions.reveal(path: "/definitely/not/a/real/path-xyz-123")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("/definitely/not/a/real/path-xyz-123"))
        } catch { XCTFail("wrong error type") }
    }

    func testResolveExpandsTildeAndPassesAbsolutePathToStore() async throws {
        let name = "mac-cli-finder-tilde-test-\(UUID().uuidString).txt"
        let fullPath = (NSHomeDirectory() as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: fullPath, contents: Data("hi".utf8))
        defer { try? FileManager.default.removeItem(atPath: fullPath) }

        try await actions.reveal(path: "~/\(name)")
        XCTAssertEqual(store.revealedPaths, [fullPath])
    }

    func testResolveRelativePathResolvesAgainstCurrentDirectory() async throws {
        let fileURL = tempDir.appendingPathComponent("scratch.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("hi".utf8))
        FileManager.default.changeCurrentDirectoryPath(tempDir.path)
        // getcwd() (and thus currentDirectoryPath) resolves the /var -> /private/var
        // symlink, so the expected path must be derived the same way rather than
        // reused from the pre-chdir tempDir URL.
        let expected = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("scratch.txt")

        try await actions.reveal(path: "scratch.txt")
        XCTAssertEqual(store.revealedPaths, [expected])
    }

    // MARK: - reveal / open / trash pass the resolved path

    func testRevealOpenTrashPassResolvedPathToStore() async throws {
        let fileURL = tempDir.appendingPathComponent("target.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("hi".utf8))

        try await actions.reveal(path: fileURL.path)
        try await actions.open(path: fileURL.path)
        try await actions.trash(path: fileURL.path)

        XCTAssertEqual(store.revealedPaths, [fileURL.path])
        XCTAssertEqual(store.openedPaths, [fileURL.path])
        XCTAssertEqual(store.trashedPaths, [fileURL.path])
    }

    // MARK: - eject

    func testEjectEmptyNameThrowsBadInput() async {
        do {
            try await actions.eject(name: "  ")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testEjectUnknownNameThrowsNotFound() async {
        do {
            try await actions.eject(name: "Bogus Drive")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("mac finder disks"))
        } catch { XCTFail("wrong error type") }
    }

    func testEjectNonEjectableDiskThrowsBadInput() async {
        do {
            try await actions.eject(name: "macintosh hd")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("not ejectable"))
        } catch { XCTFail("wrong error type") }
    }

    func testEjectResolvesCaseInsensitivelyAndCallsStoreWithCanonicalName() async throws {
        try await actions.eject(name: "backup drive")
        XCTAssertEqual(store.ejectedNames, ["Backup Drive"])
    }

    func testEjectVanishedDiskThrowsNotFound() async {
        store.vanishedDiskNames = ["Backup Drive"]
        do {
            try await actions.eject(name: "Backup Drive")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }
}
