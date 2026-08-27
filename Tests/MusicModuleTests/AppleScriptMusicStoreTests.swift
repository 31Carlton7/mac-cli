import XCTest
import Core
@testable import MusicModule

final class AppleScriptMusicStoreTests: XCTestCase {
    let fs = AppleScript.fieldSep, rs = AppleScript.recordSep

    // MARK: - Player state

    func testParsesPlayerStateWithTrack() {
        // state FS volume FS position FS trackID FS name FS artist FS album FS duration FS rating
        let row = ["playing", "42", "17", "t1", "Song", "Artist", "Album", "213", "60"].joined(separator: fs)
        let state = AppleScriptMusicStore.parsePlayerState(from: row)
        XCTAssertEqual(state.state, "playing")
        XCTAssertEqual(state.volume, 42)
        XCTAssertEqual(state.positionSeconds, 17)
        XCTAssertEqual(state.track?.id, "t1")
        XCTAssertEqual(state.track?.name, "Song")
        XCTAssertEqual(state.track?.artist, "Artist")
        XCTAssertEqual(state.track?.album, "Album")
        XCTAssertEqual(state.track?.durationSeconds, 213)
        XCTAssertEqual(state.track?.rating, 3) // (60 + 10) / 20 = 3
    }

    func testParsesPlayerStateWithoutTrackUsesNotrackSentinel() {
        // Sentinel record: state FS volume FS "-1" FS "NOTRACK"
        let row = ["stopped", "10", "-1", "NOTRACK"].joined(separator: fs)
        let state = AppleScriptMusicStore.parsePlayerState(from: row)
        XCTAssertEqual(state.state, "stopped")
        XCTAssertEqual(state.volume, 10)
        XCTAssertNil(state.track)
        XCTAssertNil(state.positionSeconds)
    }

    func testPlayerStateWithNegativePositionOmitsPosition() {
        // `player position` can itself fail inside the try and fall back to "-1"
        // even when a track IS playing; that must still read as "no position".
        let row = ["playing", "50", "-1", "t1", "Song", "Artist", "Album", "100", "0"].joined(separator: fs)
        let state = AppleScriptMusicStore.parsePlayerState(from: row)
        XCTAssertNotNil(state.track)
        XCTAssertNil(state.positionSeconds)
    }

    // MARK: - Rating mapping: (r + 10) / 20, verified boundary points
    //
    // The plan sketches "0/10/90/100 -> 0/1/4/5" as a rough illustration, but
    // that literal mapping does not hold under the stated formula: (90 + 10)
    // / 20 = 100/20 = 5, not 4, and (100 + 10) / 20 = 110/20 = 5 (integer
    // division). The actual 4/5 star boundary sits at 90 (90 rounds UP to 5;
    // 89 is the highest raw value that still rounds down to 4). These tests
    // assert the formula's real output rather than the plan's illustrative
    // numbers.

    private func ratingRow(_ raw: Int) -> String {
        ["playing", "50", "0", "t1", "n", "a", "al", "100", String(raw)].joined(separator: fs)
    }

    func testRatingMappingBoundaryZero() {
        XCTAssertEqual(AppleScriptMusicStore.parsePlayerState(from: ratingRow(0)).track?.rating, 0)
    }

    func testRatingMappingBoundaryTen() {
        XCTAssertEqual(AppleScriptMusicStore.parsePlayerState(from: ratingRow(10)).track?.rating, 1)
    }

    func testRatingMappingBoundaryEightyNine() {
        // Highest raw value that still rounds DOWN to 4 stars.
        XCTAssertEqual(AppleScriptMusicStore.parsePlayerState(from: ratingRow(89)).track?.rating, 4)
    }

    func testRatingMappingBoundaryNinety() {
        // The 4/5 star crossover: 90 rounds UP to 5, same as the 0/1
        // crossover sits at 10, not 9.
        XCTAssertEqual(AppleScriptMusicStore.parsePlayerState(from: ratingRow(90)).track?.rating, 5)
    }

    func testRatingMappingBoundaryOneHundred() {
        XCTAssertEqual(AppleScriptMusicStore.parsePlayerState(from: ratingRow(100)).track?.rating, 5)
    }

    // MARK: - Track rows (6 fields: id, name, artist, album, duration, rating)

    func testParsesTrackRows() {
        let row = ["t1", "Song One", "Artist", "Album", "180", "100"].joined(separator: fs)
            + rs + ["t2", "Song Two", "Artist2", "Album2", "200", "0"].joined(separator: fs)
        let items = AppleScriptMusicStore.parseTracks(from: row)
        XCTAssertEqual(items.map(\.id), ["t1", "t2"])
        XCTAssertEqual(items[0].name, "Song One")
        XCTAssertEqual(items[0].durationSeconds, 180)
        XCTAssertEqual(items[0].rating, 5)
        XCTAssertEqual(items[1].rating, 0)
        XCTAssertNil(items[0].playlist)
    }

    func testTrackRowsDedupeById() {
        let row = ["t1", "Song One", "Artist", "Album", "180", "100"].joined(separator: fs)
        let output = [row, row].joined(separator: rs)
        let items = AppleScriptMusicStore.parseTracks(from: output)
        XCTAssertEqual(items.count, 1)
    }

    func testMalformedTrackRowIsSkipped() {
        let row = ["t1", "Song One", "Artist", "Album", "180", "100"].joined(separator: fs)
        let output = [row, "garbage"].joined(separator: rs)
        let items = AppleScriptMusicStore.parseTracks(from: output)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "t1")
    }

    // MARK: - Playlist rows (5 fields: id, name, trackCount, specialKindText, classText)
    // Kind mapping: class contains "user" AND specialKind in ("none","") -> "user", else "system".

    func testParsesPlaylistRowUserKind() {
        let row = ["p1", "Road Trip", "12", "none", "user playlist"].joined(separator: fs)
        let infos = AppleScriptMusicStore.parsePlaylists(from: row)
        XCTAssertEqual(infos.first?.kind, "user")
        XCTAssertEqual(infos.first?.trackCount, 12)
    }

    func testParsesPlaylistRowUserKindWithEmptySpecialKind() {
        let row = ["p1", "Road Trip", "12", "", "user playlist"].joined(separator: fs)
        XCTAssertEqual(AppleScriptMusicStore.parsePlaylists(from: row).first?.kind, "user")
    }

    func testParsesPlaylistRowSystemKindWhenSpecialKindNotNone() {
        // A built-in library playlist (e.g. "Music") still reports class "user
        // playlist" but carries a non-"none" special kind -> system.
        let row = ["p1", "Music", "500", "Music", "user playlist"].joined(separator: fs)
        XCTAssertEqual(AppleScriptMusicStore.parsePlaylists(from: row).first?.kind, "system")
    }

    func testParsesPlaylistRowSystemKindWhenClassNotUser() {
        let row = ["p1", "Library", "500", "none", "library playlist"].joined(separator: fs)
        XCTAssertEqual(AppleScriptMusicStore.parsePlaylists(from: row).first?.kind, "system")
    }

    func testParsesPlaylistRowSystemKindForFolder() {
        let row = ["p1", "Genres", "0", "none", "folder playlist"].joined(separator: fs)
        XCTAssertEqual(AppleScriptMusicStore.parsePlaylists(from: row).first?.kind, "system")
    }

    func testPlaylistRowsDedupeById() {
        let row = ["p1", "Road Trip", "12", "none", "user playlist"].joined(separator: fs)
        let output = [row, row].joined(separator: rs)
        XCTAssertEqual(AppleScriptMusicStore.parsePlaylists(from: output).count, 1)
    }

    func testMalformedPlaylistRowIsSkipped() {
        let row = ["p1", "Road Trip", "12", "none", "user playlist"].joined(separator: fs)
        let output = [row, "garbage"].joined(separator: rs)
        let infos = AppleScriptMusicStore.parsePlaylists(from: output)
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].id, "p1")
    }

    func testEmptyOutputYieldsNothing() {
        XCTAssertTrue(AppleScriptMusicStore.parseTracks(from: "").isEmpty)
        XCTAssertTrue(AppleScriptMusicStore.parsePlaylists(from: "").isEmpty)
    }

    // MARK: - TIMEOUT mapping (sanctioned follow-up #2)

    func testCheckTimeoutThrowsInternalErrorForTimeoutSentinel() {
        XCTAssertThrowsError(try AppleScriptMusicStore.checkTimeout("TIMEOUT")) { error in
            XCTAssertTrue((error as NSError).localizedDescription.contains(
                "Music id lookup timed out after 30s — library may be too large for direct id addressing."
            ))
        }
    }

    func testCheckTimeoutDoesNothingForOtherOutputs() {
        XCTAssertNoThrow(try AppleScriptMusicStore.checkTimeout("NOTFOUND"))
        XCTAssertNoThrow(try AppleScriptMusicStore.checkTimeout("ok"))
    }

    // MARK: - REFUSED mapping (protected playlists that misreport as
    // user-modifiable, e.g. Favorite Songs, but reject the mutation verb)

    func testCheckRefusedThrowsBadInputWithMessagePassthrough() {
        XCTAssertThrowsError(try AppleScriptMusicStore.checkRefused(#"REFUSED:Music got an error: user playlist id 123 doesn't understand the "delete" message."#)) { error in
            guard let macError = error as? MacError else {
                return XCTFail("expected MacError, got \(error)")
            }
            XCTAssertEqual(macError.code, .badInput)
            XCTAssertEqual(macError.message,
                #"Music refused the operation: Music got an error: user playlist id 123 doesn't understand the "delete" message.. Some playlists (e.g. Favorites) are protected even though Music reports them as user playlists."#)
        }
    }

    func testCheckRefusedDoesNothingForOtherOutputs() {
        XCTAssertNoThrow(try AppleScriptMusicStore.checkRefused("NOTFOUND"))
        XCTAssertNoThrow(try AppleScriptMusicStore.checkRefused("TIMEOUT"))
        XCTAssertNoThrow(try AppleScriptMusicStore.checkRefused("ok"))
    }
}
