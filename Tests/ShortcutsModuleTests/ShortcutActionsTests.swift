import XCTest
import Core
@testable import ShortcutsModule

final class MockShortcutStore: ShortcutStore {
    var accessGranted = true
    var storedShortcuts: [ShortcutInfo] = []
    var runResults: [String: String] = [:] // id -> output
    var runCalls: [(id: String, input: String?)] = []

    private func gate() throws {
        if !accessGranted {
            throw MacError(.permissionDenied, "Shortcuts Events automation not granted. Run: mac doctor")
        }
    }

    func list() async throws -> [ShortcutInfo] {
        try gate()
        return storedShortcuts
    }

    func run(id: String, input: String?) async throws -> String {
        try gate()
        runCalls.append((id: id, input: input))
        guard let result = runResults[id] else {
            throw MacError(.badInput, "Shortcut failed: no such shortcut id \(id)")
        }
        return result
    }
}

final class ShortcutActionsTests: XCTestCase {
    var store = MockShortcutStore()
    lazy var actions = ShortcutActions(store: store)

    override func setUp() {
        super.setUp()
        store = MockShortcutStore()
        actions = ShortcutActions(store: store)
        store.storedShortcuts = [
            ShortcutInfo(id: "s-weather", name: "Get Weather", folder: "Utilities"),
            ShortcutInfo(id: "s-zzz", name: "zzz Last", folder: nil),
            ShortcutInfo(id: "s-aaa", name: "Aaa First", folder: nil),
            ShortcutInfo(id: "s-dup-1", name: "Dup", folder: nil),
            ShortcutInfo(id: "s-dup-2", name: "Dup", folder: "Utilities"),
        ]
        store.runResults = ["s-weather": "72F and sunny", "s-dup-1": "ran dup 1"]
    }

    // MARK: - list

    func testListSortsByNameLocalizedCaseInsensitive() async throws {
        let names = try await actions.list().map(\.name)
        XCTAssertEqual(names, ["Aaa First", "Dup", "Dup", "Get Weather", "zzz Last"])
    }

    func testListPermissionDeniedPropagates() async {
        store.accessGranted = false
        do {
            _ = try await actions.list()
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - run by id

    func testRunByIDIsDirectAndBypassesNameResolution() async throws {
        let result = try await actions.run(nameOrID: "s-weather", input: nil, isID: true)
        XCTAssertEqual(result, "72F and sunny")
        XCTAssertEqual(store.runCalls.map(\.id), ["s-weather"])
    }

    func testRunByIDPassesInputThrough() async throws {
        _ = try await actions.run(nameOrID: "s-weather", input: "hello", isID: true)
        XCTAssertEqual(store.runCalls.last?.input, "hello")
    }

    // MARK: - run by name

    func testRunByUnknownNameThrowsNotFound() async {
        do {
            _ = try await actions.run(nameOrID: "Nope", input: nil, isID: false)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("mac shortcuts list"))
        } catch { XCTFail("wrong error type") }
    }

    func testRunByAmbiguousNameThrowsBadInputListingBothIDsAndIdHint() async {
        do {
            _ = try await actions.run(nameOrID: "dup", input: nil, isID: false)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("s-dup-1"))
            XCTAssertTrue(error.message.contains("s-dup-2"))
            XCTAssertTrue(error.message.contains("--id"))
        } catch { XCTFail("wrong error type") }
    }

    func testRunByExactNameResolvesCaseInsensitively() async throws {
        let result = try await actions.run(nameOrID: "GET WEATHER", input: nil, isID: false)
        XCTAssertEqual(result, "72F and sunny")
        XCTAssertEqual(store.runCalls.map(\.id), ["s-weather"])
    }
}
