import XCTest
@testable import TVModule

final class TVScriptsTests: XCTestCase {
    private func allVariants() -> [(name: String, script: String)] {
        [
            ("playerState", TVScripts.playerState()),
            ("resume", TVScripts.resume()),
            ("pause", TVScripts.pause()),
            ("list", TVScripts.list(limit: 25)),
            ("play", TVScripts.play(id: #"tr"1"#)),
        ]
    }

    func testEveryScriptHasTimeout() {
        for (name, script) in allVariants() {
            XCTAssertTrue(script.contains("with timeout"), "\(name) missing timeout: \(script.prefix(80))")
        }
    }

    /// The only `whose` allowed anywhere is the sanctioned by-persistent-ID
    /// shape, wrapped in `with timeout of 30 seconds`. Mirrors
    /// MusicScriptsTests' tightened check: every substring following "whose"
    /// must match the FULL sanctioned shape through its closing quote+paren,
    /// and the count of "whose" occurrences must equal the count of 30s
    /// timeout blocks.
    func testOnlyWhoseOccurrenceIsSanctionedByPersistentID() {
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

    func testPlayScriptSanctionedWhoseShapeWithTimeoutAndSentinels() {
        let script = TVScripts.play(id: "t1")
        XCTAssertTrue(script.contains("whose persistent ID is"))
        XCTAssertTrue(script.contains("with timeout of 30 seconds"))
        XCTAssertTrue(script.contains("NOTFOUND"))
        XCTAssertTrue(script.contains("TIMEOUT"))
        XCTAssertTrue(script.contains("errNum"))
        XCTAssertTrue(script.contains("-1712"))
        XCTAssertTrue(script.contains("play theTrack"))
    }

    func testEscapingOfIDInPlayScript() {
        let script = TVScripts.play(id: #"id"with"quotes"#)
        XCTAssertTrue(script.contains(#"id\"with\"quotes"#))
    }

    func testPlayerStateSentinelAndArtistFromShow() {
        let script = TVScripts.playerState()
        XCTAssertTrue(script.contains("NOTRACK"))
        XCTAssertTrue(script.contains("player state as text"))
        XCTAssertTrue(script.contains("current track"))
        XCTAssertTrue(script.contains("show of curTrack"))
        // "st" is reserved in TV's terminology -- must not appear as a bare local.
        XCTAssertFalse(script.contains(" st "))
        XCTAssertFalse(script.contains("set st "))
    }

    func testListScriptBoundAndHasNoWhose() {
        let script = TVScripts.list(limit: 7)
        XCTAssertTrue(script.contains("if k > 7 then set k to 7"))
        XCTAssertTrue(script.contains("tracks 1 thru k of library playlist 1"))
        XCTAssertTrue(script.contains("media kind of t"))
        XCTAssertTrue(script.contains("season number of t"))
        XCTAssertTrue(script.contains("episode number of t"))
        XCTAssertFalse(script.contains("whose"))
    }

    /// `names` is a reserved search-scope enumerator in TV.app's terminology
    /// (`kSrS`) -- `set names to ...` fails to compile inside `tell
    /// application "TV"`. Caught by osacompile; regression-tested here so it
    /// can't silently come back.
    func testListScriptDoesNotUseReservedNamesLocal() {
        let script = TVScripts.list(limit: 10)
        XCTAssertFalse(script.contains("set names to"))
        XCTAssertTrue(script.contains("set theNames to"))
    }

    func testListScriptGuardsEmptyLibrary() {
        let script = TVScripts.list(limit: 50)
        XCTAssertTrue(script.contains("if k > 0 then"))
    }

    /// Live bug (measured on a library with exactly one `shared track`):
    /// `tracks 1 thru k of library playlist 1` with k=1 resolves to a BARE
    /// track reference, not a list, so `item 1 of <that reference>` fails
    /// ("Can't get item 1 of shared track id ..."). The `as list` coercion
    /// trick is reliable for property-value fetches (text/numbers) but NOT
    /// for object-specifier results. Fix: index the container directly with
    /// `track i of library playlist 1` per iteration instead of holding an
    /// object-range variable and indexing into it.
    func testListScriptIndexesTracksDirectlyNotViaObjectRange() {
        let script = TVScripts.list(limit: 10)
        XCTAssertFalse(script.contains("item i of theTracks"))
        XCTAssertFalse(script.contains("set theTracks to"))
        XCTAssertTrue(script.contains("set t to track i of library playlist 1"))
    }
}
