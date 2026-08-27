import XCTest
@testable import MusicModule

final class MusicScriptsTests: XCTestCase {
    /// Every script variant this module can emit, with representative args
    /// (including quote-bearing values to exercise escaping).
    private func allVariants() -> [(name: String, script: String)] {
        [
            ("playerState", MusicScripts.playerState()),
            ("resume", MusicScripts.resume()),
            ("pause", MusicScripts.pause()),
            ("next", MusicScripts.next()),
            ("previous", MusicScripts.previous()),
            ("setVolume", MusicScripts.setVolume(42)),
            ("search", MusicScripts.search(query: #"Bob's "Song""#, limit: 25)),
            ("playlists", MusicScripts.playlists()),
            ("createPlaylist", MusicScripts.createPlaylist(name: #"My "Chill" Mix"#)),
            ("deletePlaylist", MusicScripts.deletePlaylist(id: #"pl"1"#)),
            ("playTrack", MusicScripts.playTrack(id: #"tr"1"#)),
            ("playPlaylist", MusicScripts.playPlaylist(id: #"pl"1"#)),
            ("addTrack", MusicScripts.addTrack(id: #"tr"1"#, toPlaylist: #"pl"1"#)),
            ("removeTrack", MusicScripts.removeTrack(id: #"tr"1"#, fromPlaylist: #"pl"1"#)),
            ("rate", MusicScripts.rate(trackID: #"tr"1"#, rating0to100: 80)),
        ]
    }

    func testEveryScriptHasTimeout() {
        for (name, script) in allVariants() {
            XCTAssertTrue(script.contains("with timeout"), "\(name) missing timeout: \(script.prefix(80))")
        }
    }

    /// The only `whose` allowed anywhere is the sanctioned by-persistent-ID
    /// shape, wrapped in `with timeout of 30 seconds`. Two checks per script:
    /// (1) every substring immediately following "whose" matches the FULL
    /// sanctioned shape through its closing quote+paren — not just the
    /// " persistent ID is" prefix, which would also accept a shape that
    /// diverges later (e.g. a stray extra clause tacked on before the
    /// paren); (2) the count of "whose" occurrences equals the count of
    /// "with timeout of 30 seconds" occurrences, since every sanctioned
    /// `whose` lives inside exactly one such 30s timeout block and vice versa.
    func testOnlyWhoseOccurrenceIsSanctionedByPersistentID() {
        // ` persistent ID is "<escaped id, i.e. any run of non-quote/backslash
        // chars or backslash-escaped pairs>"` up to and including the closing
        // paren of the `(first ... whose ...)` expression.
        let sanctionedSuffix = try! NSRegularExpression(
            pattern: #"^ persistent ID is "([^"\\]|\\.)*"\)"#
        )
        for (name, script) in allVariants() {
            let whoseCount = script.components(separatedBy: "whose").count - 1
            let timeoutCount = script.components(separatedBy: "with timeout of 30 seconds").count - 1
            XCTAssertEqual(whoseCount, timeoutCount,
                           "\(name): \(whoseCount) 'whose' occurrence(s) but \(timeoutCount) 30s timeout block(s)")

            let parts = script.components(separatedBy: "whose")
            guard parts.count > 1 else { continue }
            for suffix in parts.dropFirst() {
                let range = NSRange(suffix.startIndex..., in: suffix)
                XCTAssertNotNil(
                    sanctionedSuffix.firstMatch(in: suffix, range: range),
                    "\(name): unsanctioned whose usage: ...whose\(suffix.prefix(60))"
                )
            }
        }
    }

    func testSanctionedWhoseShapesAreWrappedInThirtySecondTimeout() {
        let scripts = [
            MusicScripts.playTrack(id: "t1"),
            MusicScripts.playPlaylist(id: "p1"),
            MusicScripts.addTrack(id: "t1", toPlaylist: "p1"),
            MusicScripts.removeTrack(id: "t1", fromPlaylist: "p1"),
            MusicScripts.deletePlaylist(id: "p1"),
            MusicScripts.rate(trackID: "t1", rating0to100: 60),
        ]
        for script in scripts {
            XCTAssertTrue(script.contains("whose persistent ID is"))
            XCTAssertTrue(script.contains("with timeout of 30 seconds"))
            XCTAssertTrue(script.contains("NOTFOUND"))
            XCTAssertTrue(script.contains("TIMEOUT"))
            XCTAssertTrue(script.contains("errNum"))
            XCTAssertTrue(script.contains("-1712"))
        }
    }

    func testPlaylistsLoopHasNoWhose() {
        let script = MusicScripts.playlists()
        XCTAssertFalse(script.contains("whose"))
        XCTAssertTrue(script.contains("repeat with p in playlists"))
        XCTAssertTrue(script.contains("special kind of p"))
        XCTAssertTrue(script.contains("class of p"))
    }

    func testSearchScriptShapeAndBound() {
        let script = MusicScripts.search(query: #"a "b" c"#, limit: 5)
        XCTAssertTrue(script.contains("search library playlist 1 for"))
        XCTAssertTrue(script.contains(#"a \"b\" c"#)) // escaped quotes
        XCTAssertTrue(script.contains("if n > 5 then set n to 5"))
        XCTAssertFalse(script.contains("whose"))
    }

    func testEscapingOfQueryNameAndID() {
        let query = MusicScripts.search(query: #"weird\name"#, limit: 10)
        XCTAssertTrue(query.contains(#"weird\\name"#))

        let name = MusicScripts.createPlaylist(name: #"Say "Hi""#)
        XCTAssertTrue(name.contains(#"Say \"Hi\""#))

        let id = MusicScripts.playTrack(id: #"id"with"quotes"#)
        XCTAssertTrue(id.contains(#"id\"with\"quotes"#))
    }

    func testPlayerStateSentinelAndFields() {
        let script = MusicScripts.playerState()
        XCTAssertTrue(script.contains("NOTRACK"))
        XCTAssertTrue(script.contains("player state as text"))
        XCTAssertTrue(script.contains("current track"))
        XCTAssertTrue(script.contains("player position"))
    }

    func testRateScriptEmbedsRawRatingValue() {
        let script = MusicScripts.rate(trackID: "t1", rating0to100: 80)
        XCTAssertTrue(script.contains("set rating of theTrack to 80"))
    }

    func testAddAndRemoveTrackLocateInDifferentContainers() {
        let add = MusicScripts.addTrack(id: "t1", toPlaylist: "p1")
        XCTAssertTrue(add.contains("first track of library playlist 1 whose persistent ID is"))
        XCTAssertTrue(add.contains("first playlist whose persistent ID is"))
        XCTAssertTrue(add.contains("duplicate theTrack to thePlaylist"))

        let remove = MusicScripts.removeTrack(id: "t1", fromPlaylist: "p1")
        XCTAssertTrue(remove.contains("first track of thePlaylist whose persistent ID is"))
        XCTAssertTrue(remove.contains("delete theTrack"))
    }

    func testCreatePlaylistEmitsPlaylistRecord() {
        let script = MusicScripts.createPlaylist(name: "Road Trip")
        XCTAssertTrue(script.contains("make new user playlist with properties"))
        XCTAssertTrue(script.contains("special kind of p"))
        XCTAssertTrue(script.contains("class of p"))
    }

    // MARK: - Mutation verbs refuse cleanly (protected playlists that
    // misreport as class=user playlist/specialKind=none, e.g. Favorite
    // Songs, still reject `delete`/`duplicate` at the verb itself — that
    // has to surface as a sentinel, not a raw AppleScript error).

    func testDeletePlaylistWrapsVerbAndRefusesCleanly() {
        let script = MusicScripts.deletePlaylist(id: "p1")
        XCTAssertTrue(script.contains("try\n"))
        XCTAssertTrue(script.contains("delete thePlaylist"))
        XCTAssertTrue(script.contains("on error m"))
        XCTAssertTrue(script.contains(#"return "REFUSED:" & m"#))
    }

    func testAddTrackWrapsDuplicateVerbAndRefusesCleanly() {
        let script = MusicScripts.addTrack(id: "t1", toPlaylist: "p1")
        XCTAssertTrue(script.contains("duplicate theTrack to thePlaylist"))
        XCTAssertTrue(script.contains("on error m"))
        XCTAssertTrue(script.contains(#"return "REFUSED:" & m"#))
    }

    func testRemoveTrackWrapsDeleteVerbAndRefusesCleanly() {
        let script = MusicScripts.removeTrack(id: "t1", fromPlaylist: "p1")
        XCTAssertTrue(script.contains("delete theTrack"))
        XCTAssertTrue(script.contains("on error m"))
        XCTAssertTrue(script.contains(#"return "REFUSED:" & m"#))
    }
}
