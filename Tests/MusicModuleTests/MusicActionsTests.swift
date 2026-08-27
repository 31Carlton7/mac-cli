import XCTest
import Core
@testable import MusicModule

final class MockMusicStore: MusicStore {
    var accessGranted = true
    var storedPlaylists: [PlaylistInfo] = []
    var storedTrackIDs: Set<String> = []
    var state = PlayerState(state: "stopped", volume: 50, track: nil, positionSeconds: nil)

    var resumeCalled = false
    var pauseCalled = false
    var nextCalled = false
    var previousCalled = false
    var setVolumeCalls: [Int] = []
    var playedPlaylistIDs: [String] = []
    var playedTrackIDs: [String] = []
    var searchCalls: [(query: String, limit: Int)] = []
    var searchResults: [TrackItem] = []
    var createdPlaylistNames: [String] = []
    var addedTracks: [(id: String, playlistID: String)] = []
    var removedTracks: [(id: String, playlistID: String)] = []
    var deletedPlaylistIDs: [String] = []
    var rateCalls: [(trackID: String, rating0to100: Int)] = []

    private func gate() throws {
        if !accessGranted {
            throw MacError(.permissionDenied, "Music automation not granted. Run: mac doctor")
        }
    }

    func playerState() async throws -> PlayerState {
        try gate()
        return state
    }

    func resume() async throws { try gate(); resumeCalled = true }
    func pause() async throws { try gate(); pauseCalled = true }
    func next() async throws { try gate(); nextCalled = true }
    func previous() async throws { try gate(); previousCalled = true }

    func setVolume(_ volume: Int) async throws {
        try gate()
        setVolumeCalls.append(volume)
    }

    func playPlaylist(id: String) async throws -> Bool {
        try gate()
        guard storedPlaylists.contains(where: { $0.id == id }) else { return false }
        playedPlaylistIDs.append(id)
        return true
    }

    func playTrack(id: String) async throws -> Bool {
        try gate()
        guard storedTrackIDs.contains(id) else { return false }
        playedTrackIDs.append(id)
        return true
    }

    func search(_ query: String, limit: Int) async throws -> [TrackItem] {
        try gate()
        searchCalls.append((query, limit))
        return Array(searchResults.prefix(limit))
    }

    func playlists() async throws -> [PlaylistInfo] {
        try gate()
        return storedPlaylists
    }

    func createPlaylist(name: String) async throws -> PlaylistInfo {
        try gate()
        createdPlaylistNames.append(name)
        let info = PlaylistInfo(id: "new-\(createdPlaylistNames.count)", name: name, trackCount: 0, kind: "user")
        storedPlaylists.append(info)
        return info
    }

    func addTrack(id: String, toPlaylist playlistID: String) async throws -> Bool {
        try gate()
        guard storedTrackIDs.contains(id), storedPlaylists.contains(where: { $0.id == playlistID }) else { return false }
        addedTracks.append((id, playlistID))
        return true
    }

    func removeTrack(id: String, fromPlaylist playlistID: String) async throws -> Bool {
        try gate()
        guard storedTrackIDs.contains(id), storedPlaylists.contains(where: { $0.id == playlistID }) else { return false }
        removedTracks.append((id, playlistID))
        return true
    }

    func deletePlaylist(id: String) async throws -> Bool {
        try gate()
        guard let idx = storedPlaylists.firstIndex(where: { $0.id == id }) else { return false }
        storedPlaylists.remove(at: idx)
        deletedPlaylistIDs.append(id)
        return true
    }

    func rate(trackID: String, rating0to100: Int) async throws -> Bool {
        try gate()
        guard storedTrackIDs.contains(trackID) else { return false }
        rateCalls.append((trackID, rating0to100))
        return true
    }
}

final class MusicActionsTests: XCTestCase {
    var store = MockMusicStore()
    lazy var actions = MusicActions(store: store)

    override func setUp() {
        super.setUp()
        store = MockMusicStore()
        actions = MusicActions(store: store)
        store.storedPlaylists = [
            PlaylistInfo(id: "pl-chill-1", name: "Chill", trackCount: 3, kind: "user"),
            PlaylistInfo(id: "pl-chill-2", name: "Chill", trackCount: 5, kind: "user"),
            PlaylistInfo(id: "pl-workout", name: "Workout", trackCount: 10, kind: "user"),
            PlaylistInfo(id: "pl-library", name: "Library", trackCount: 100, kind: "system"),
        ]
        store.storedTrackIDs = ["t1", "t2"]
    }

    // MARK: - play

    func testPlayWithBothFlagsThrowsBadInput() async {
        do {
            try await actions.play(playlist: "Workout", trackID: "t1")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("not both"))
        } catch { XCTFail("wrong error type") }
    }

    func testPlayWithNoFlagsResumes() async throws {
        try await actions.play(playlist: nil, trackID: nil)
        XCTAssertTrue(store.resumeCalled)
    }

    func testPlayByAmbiguousNameListsSortedCappedFiveCandidates() async {
        // Insertion order deliberately differs from sorted order, and there are more than
        // 5 matches, so the fix must sort before capping rather than capping insertion order.
        store.storedPlaylists = ["p9", "p3", "p7", "p1", "p5", "p2"].map {
            PlaylistInfo(id: $0, name: "Dup", trackCount: 0, kind: "user")
        }
        do {
            try await actions.play(playlist: "dup", trackID: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            for id in ["p1", "p2", "p3", "p5", "p7"] {
                XCTAssertTrue(error.message.contains(id), "expected message to contain \(id): \(error.message)")
            }
            XCTAssertFalse(error.message.contains("p9"), "expected message to omit p9: \(error.message)")
        } catch { XCTFail("wrong error type") }
    }

    func testPlayByAmbiguousNameThrowsBadInputListingBothIDs() async {
        do {
            try await actions.play(playlist: "chill", trackID: nil)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("pl-chill-1"))
            XCTAssertTrue(error.message.contains("pl-chill-2"))
            XCTAssertTrue(error.message.contains("mac music playlists"))
        } catch { XCTFail("wrong error type") }
    }

    func testPlayByExactIDBypassesAmbiguity() async throws {
        // "pl-chill-1" is itself a valid playlist id, even though the name "Chill" is ambiguous.
        try await actions.play(playlist: "pl-chill-1", trackID: nil)
        XCTAssertEqual(store.playedPlaylistIDs, ["pl-chill-1"])
    }

    func testPlayByUnambiguousNameResolvesCaseInsensitively() async throws {
        try await actions.play(playlist: "WORKOUT", trackID: nil)
        XCTAssertEqual(store.playedPlaylistIDs, ["pl-workout"])
    }

    func testPlayByUnknownPlaylistThrowsNotFound() async {
        do {
            try await actions.play(playlist: "Bogus", trackID: nil)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("mac music playlists"))
        } catch { XCTFail("wrong error type") }
    }

    func testPlayByTrackIDCallsPlayTrack() async throws {
        try await actions.play(playlist: nil, trackID: "t1")
        XCTAssertEqual(store.playedTrackIDs, ["t1"])
    }

    func testPlayByUnknownTrackIDThrowsNotFound() async {
        do {
            try await actions.play(playlist: nil, trackID: "bogus")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertTrue(error.message.contains("mac music search"))
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - transport passthrough

    func testNowReturnsPlayerState() async throws {
        store.state = PlayerState(state: "playing", volume: 42, track: nil, positionSeconds: 5)
        let result = try await actions.now()
        XCTAssertEqual(result.state, "playing")
        XCTAssertEqual(result.volume, 42)
    }

    func testPauseNextPreviousPassthrough() async throws {
        try await actions.pause()
        try await actions.next()
        try await actions.previous()
        XCTAssertTrue(store.pauseCalled)
        XCTAssertTrue(store.nextCalled)
        XCTAssertTrue(store.previousCalled)
    }

    // MARK: - volume

    func testVolumeGetReturnsPlayerStateVolume() async throws {
        store.state = PlayerState(state: "playing", volume: 33, track: nil, positionSeconds: nil)
        let level = try await actions.volume(nil)
        XCTAssertEqual(level, 33)
        XCTAssertTrue(store.setVolumeCalls.isEmpty)
    }

    func testVolumeSetCallsStoreAndEchoesLevel() async throws {
        let level = try await actions.volume(75)
        XCTAssertEqual(level, 75)
        XCTAssertEqual(store.setVolumeCalls, [75])
    }

    func testVolumeSetOutOfRangeThrowsBadInput() async {
        do {
            _ = try await actions.volume(101)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            // `volume` is a positional argument, not a flag — the message must
            // not tell agents to pass a nonexistent `--volume` flag.
            XCTAssertEqual(error.message, "volume must be between 0 and 100.")
        } catch { XCTFail("wrong error type") }
        do {
            _ = try await actions.volume(-1)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertEqual(error.message, "volume must be between 0 and 100.")
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - search

    func testSearchEmptyQueryThrowsBadInput() async {
        do {
            _ = try await actions.search(query: "   ", limit: 20)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testSearchLimitOutOfRangeThrowsBadInput() async {
        do {
            _ = try await actions.search(query: "a", limit: 0)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
        do {
            _ = try await actions.search(query: "a", limit: 201)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testSearchTrimsQueryAndPassesLimitToStore() async throws {
        store.searchResults = [
            TrackItem(id: "t1", name: "Song", artist: "Artist", album: "Album",
                     durationSeconds: 100, rating: 0, playlist: nil)
        ]
        let results = try await actions.search(query: "  a  ", limit: 20)
        XCTAssertEqual(results.map(\.id), ["t1"])
        XCTAssertEqual(store.searchCalls.count, 1)
        XCTAssertEqual(store.searchCalls[0].query, "a")
        XCTAssertEqual(store.searchCalls[0].limit, 20)
    }

    // MARK: - playlists

    func testPlaylistsPassthrough() async throws {
        let all = try await actions.playlists()
        XCTAssertEqual(all.count, 4)
    }

    // MARK: - playlistCreate

    func testPlaylistCreateEmptyNameThrowsBadInput() async {
        do {
            _ = try await actions.playlistCreate(name: "  ")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
        } catch { XCTFail("wrong error type") }
    }

    func testPlaylistCreateDuplicateNameThrowsBadInputCaseInsensitively() async {
        do {
            _ = try await actions.playlistCreate(name: "chill")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.lowercased().contains("already exists"))
        } catch { XCTFail("wrong error type") }
    }

    func testPlaylistCreateTrimsAndCreatesNewPlaylist() async throws {
        let created = try await actions.playlistCreate(name: "  Road Trip  ")
        XCTAssertEqual(created.name, "Road Trip")
        XCTAssertEqual(store.createdPlaylistNames, ["Road Trip"])
    }

    // MARK: - playlistAdd / playlistRemove / playlistDelete: kind guard

    func testPlaylistAddToSystemPlaylistThrowsBadInput() async {
        do {
            try await actions.playlistAdd(playlist: "Library", trackID: "t1")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("system playlist"))
        } catch { XCTFail("wrong error type") }
    }

    func testPlaylistRemoveFromSystemPlaylistThrowsBadInput() async {
        do {
            try await actions.playlistRemove(playlist: "Library", trackID: "t1")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("system playlist"))
        } catch { XCTFail("wrong error type") }
    }

    func testPlaylistDeleteSystemPlaylistThrowsBadInput() async {
        do {
            try await actions.playlistDelete(name: "Library")
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertTrue(error.message.contains("system playlist"))
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - playlistAdd / playlistRemove / playlistDelete: happy paths + notFound

    func testPlaylistAddSuccessRecordsMutation() async throws {
        try await actions.playlistAdd(playlist: "Workout", trackID: "t1")
        XCTAssertEqual(store.addedTracks.count, 1)
        XCTAssertEqual(store.addedTracks[0].id, "t1")
        XCTAssertEqual(store.addedTracks[0].playlistID, "pl-workout")
    }

    func testPlaylistAddUnknownTrackThrowsNotFound() async {
        do {
            try await actions.playlistAdd(playlist: "Workout", trackID: "bogus")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    func testPlaylistRemoveSuccessRecordsMutation() async throws {
        try await actions.playlistRemove(playlist: "Workout", trackID: "t2")
        XCTAssertEqual(store.removedTracks.count, 1)
        XCTAssertEqual(store.removedTracks[0].id, "t2")
        XCTAssertEqual(store.removedTracks[0].playlistID, "pl-workout")
    }

    func testPlaylistDeleteSuccessRemovesFromStore() async throws {
        try await actions.playlistDelete(name: "Workout")
        XCTAssertEqual(store.deletedPlaylistIDs, ["pl-workout"])
    }

    func testPlaylistDeleteUnknownNameThrowsNotFound() async {
        do {
            try await actions.playlistDelete(name: "Bogus")
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
        } catch { XCTFail("wrong error type") }
    }

    // MARK: - rate

    func testRateValidStarsMapsToTimes20() async throws {
        try await actions.rate(trackID: "t1", stars: 3)
        XCTAssertEqual(store.rateCalls.count, 1)
        XCTAssertEqual(store.rateCalls[0].trackID, "t1")
        XCTAssertEqual(store.rateCalls[0].rating0to100, 60)
    }

    func testRateZeroStarsMapsToZero() async throws {
        try await actions.rate(trackID: "t1", stars: 0)
        XCTAssertEqual(store.rateCalls[0].rating0to100, 0)
    }

    func testRateFiveStarsMapsTo100() async throws {
        try await actions.rate(trackID: "t1", stars: 5)
        XCTAssertEqual(store.rateCalls[0].rating0to100, 100)
    }

    func testRateOutOfRangeThrowsBadInput() async {
        do {
            try await actions.rate(trackID: "t1", stars: 6)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            // `stars` is a positional argument, not a flag — the message must
            // not tell agents to pass a nonexistent `--stars` flag.
            XCTAssertEqual(error.message, "stars must be between 0 and 5.")
        } catch { XCTFail("wrong error type") }
        do {
            try await actions.rate(trackID: "t1", stars: -1)
            XCTFail("expected badInput")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .badInput)
            XCTAssertEqual(error.message, "stars must be between 0 and 5.")
        } catch { XCTFail("wrong error type") }
    }

    func testRateUnknownTrackThrowsNotFound() async {
        do {
            try await actions.rate(trackID: "bogus", stars: 3)
            XCTFail("expected notFound")
        } catch let error as MacError {
            XCTAssertEqual(error.code, .notFound)
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
