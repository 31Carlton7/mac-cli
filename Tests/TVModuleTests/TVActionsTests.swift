import XCTest
import Core
@testable import TVModule

final class MockTVStore: TVStore {
    var accessGranted = true
    var state = PlayerState(state: "stopped", volume: 50, track: nil, positionSeconds: nil)
    var storedItemIDs: Set<String> = []
    var listResults: [TVItem] = []

    var pauseCalled = false
    var resumeCalled = false
    var listCalls: [Int] = []
    var playedIDs: [String] = []

    private func gate() throws {
        if !accessGranted {
            throw MacError(.permissionDenied, "TV automation not granted. Run: mac doctor")
        }
    }

    func playerState() async throws -> PlayerState {
        try gate()
        return state
    }

    func pause() async throws { try gate(); pauseCalled = true }
    func resume() async throws { try gate(); resumeCalled = true }

    func list(limit: Int) async throws -> [TVItem] {
        try gate()
        listCalls.append(limit)
        return Array(listResults.prefix(limit))
    }

    func play(id: String) async throws -> Bool {
        try gate()
        guard storedItemIDs.contains(id) else { return false }
        playedIDs.append(id)
        return true
    }
}

final class TVActionsTests: XCTestCase {
    var store = MockTVStore()
    lazy var actions = TVActions(store: store)

    override func setUp() {
        super.setUp()
        store = MockTVStore()
        actions = TVActions(store: store)
        store.storedItemIDs = ["v1", "v2"]
        store.listResults = [
            TVItem(id: "v1", name: "Pilot", kind: "episode", show: "Some Show", seasonNumber: 1, episodeNumber: 1),
            TVItem(id: "v2", name: "A Movie", kind: "movie", show: nil, seasonNumber: nil, episodeNumber: nil),
        ]
    }

    // MARK: - transport passthrough

    func testNowReturnsPlayerState() async throws {
        store.state = PlayerState(state: "playing", volume: 42, track: nil, positionSeconds: 5)
        let result = try await actions.now()
        XCTAssertEqual(result.state, "playing")
        XCTAssertEqual(result.volume, 42)
    }

    func testPauseAndResumePassthrough() async throws {
        try await actions.pause()
        try await actions.resume()
        XCTAssertTrue(store.pauseCalled)
        XCTAssertTrue(store.resumeCalled)
    }

    // MARK: - list

    func testListValidatesLimitRange() async {
        do {
            _ = try await actions.list(limit: 0)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
        do {
            _ = try await actions.list(limit: 501)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testListPassesLimitToStore() async throws {
        let items = try await actions.list(limit: 1)
        XCTAssertEqual(items.map(\.id), ["v1"])
        XCTAssertEqual(store.listCalls, [1])
    }

    // MARK: - play

    func testPlayByKnownIDCallsStore() async throws {
        try await actions.play(id: "v1")
        XCTAssertEqual(store.playedIDs, ["v1"])
    }

    func testPlayByUnknownIDThrowsNotFound() async {
        do {
            try await actions.play(id: "bogus")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("mac tv list"))
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - permission propagation

    func testPermissionDeniedPropagates() async {
        store.accessGranted = false
        do {
            _ = try await actions.now()
            XCTFail("expected permissionDenied")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }
}
