import XCTest
import Core
@testable import TVModule

final class AppleScriptTVStoreTests: XCTestCase {
    let fs = AppleScript.fieldSep, rs = AppleScript.recordSep

    // MARK: - Player state (9-field shape reused from Music; artist <- show, album always "")

    func testParsesPlayerStateWithTrackUsesShowAsArtistAndEmptyAlbum() {
        // state FS volume FS position FS trackID FS name FS artist(show) FS album("") FS duration FS rating
        let row = ["playing", "30", "17", "v1", "Pilot", "Some Show", "", "1320", "60"].joined(separator: fs)
        let state = AppleScriptTVStore.parsePlayerState(from: row)
        XCTAssertEqual(state.state, "playing")
        XCTAssertEqual(state.volume, 30)
        XCTAssertEqual(state.positionSeconds, 17)
        XCTAssertEqual(state.track?.id, "v1")
        XCTAssertEqual(state.track?.name, "Pilot")
        XCTAssertEqual(state.track?.artist, "Some Show")
        XCTAssertEqual(state.track?.album, "")
        XCTAssertEqual(state.track?.durationSeconds, 1320)
        XCTAssertEqual(state.track?.rating, 3) // (60 + 10) / 20 = 3
    }

    func testParsesPlayerStateWithoutTrackUsesNotrackSentinel() {
        let row = ["stopped", "10", "-1", "NOTRACK"].joined(separator: fs)
        let state = AppleScriptTVStore.parsePlayerState(from: row)
        XCTAssertEqual(state.state, "stopped")
        XCTAssertEqual(state.volume, 10)
        XCTAssertNil(state.track)
        XCTAssertNil(state.positionSeconds)
    }

    // MARK: - List rows (6 fields: id, name, kindText, showText, seasonText, episodeText)

    func testParsesListRowKindMappingMovie() {
        let row = ["v1", "A Movie", "Movie", "", "", ""].joined(separator: fs)
        let items = AppleScriptTVStore.parseItems(from: row)
        XCTAssertEqual(items.first?.kind, "movie")
        XCTAssertNil(items.first?.show)
        XCTAssertNil(items.first?.seasonNumber)
        XCTAssertNil(items.first?.episodeNumber)
    }

    func testParsesListRowKindMappingEpisode() {
        let row = ["v1", "Pilot", "TV show", "Some Show", "1", "1"].joined(separator: fs)
        let items = AppleScriptTVStore.parseItems(from: row)
        XCTAssertEqual(items.first?.kind, "episode")
        XCTAssertEqual(items.first?.show, "Some Show")
        XCTAssertEqual(items.first?.seasonNumber, 1)
        XCTAssertEqual(items.first?.episodeNumber, 1)
    }

    func testParsesListRowKindMappingOther() {
        let row = ["v1", "Home Video", "Home Video", "", "", ""].joined(separator: fs)
        let items = AppleScriptTVStore.parseItems(from: row)
        XCTAssertEqual(items.first?.kind, "other")
    }

    func testSeasonAndEpisodeSentinelsMapToNil() {
        let dash = ["v1", "Clip", "Home Video", "", "-1", "-1"].joined(separator: fs)
        let items = AppleScriptTVStore.parseItems(from: dash)
        XCTAssertNil(items.first?.seasonNumber)
        XCTAssertNil(items.first?.episodeNumber)
    }

    func testListRowsDedupeById() {
        let row = ["v1", "Pilot", "TV show", "Some Show", "1", "1"].joined(separator: fs)
        let output = [row, row].joined(separator: rs)
        XCTAssertEqual(AppleScriptTVStore.parseItems(from: output).count, 1)
    }

    func testMalformedListRowIsSkipped() {
        let row = ["v1", "Pilot", "TV show", "Some Show", "1", "1"].joined(separator: fs)
        let output = [row, "garbage"].joined(separator: rs)
        let items = AppleScriptTVStore.parseItems(from: output)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "v1")
    }

    func testEmptyOutputYieldsNothing() {
        XCTAssertTrue(AppleScriptTVStore.parseItems(from: "").isEmpty)
    }

    // MARK: - TIMEOUT mapping

    func testCheckTimeoutThrowsInternalErrorForTimeoutSentinel() {
        XCTAssertThrowsError(try AppleScriptTVStore.checkTimeout("TIMEOUT")) { error in
            XCTAssertTrue((error as NSError).localizedDescription.contains(
                "TV id lookup timed out after 30s — library may be too large for direct id addressing."
            ))
        }
    }

    func testCheckTimeoutDoesNothingForOtherOutputs() {
        XCTAssertNoThrow(try AppleScriptTVStore.checkTimeout("NOTFOUND"))
        XCTAssertNoThrow(try AppleScriptTVStore.checkTimeout("ok"))
    }
}
