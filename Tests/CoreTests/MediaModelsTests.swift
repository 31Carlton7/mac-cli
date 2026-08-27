import XCTest
@testable import Core

final class MediaModelsTests: XCTestCase {
    func testTrackItemJSONSchema() throws {
        let track = TrackItem(id: "t1", name: "Song", artist: "Artist", album: "Album",
                              durationSeconds: 180, rating: 4, playlist: nil)
        let json = String(data: try Output.encoder.encode(track), encoding: .utf8)!
        XCTAssertEqual(json, #"{"album":"Album","artist":"Artist","durationSeconds":180,"id":"t1","name":"Song","rating":4}"#)

        let withPlaylist = TrackItem(id: "t1", name: "Song", artist: "Artist", album: "Album",
                                     durationSeconds: 180, rating: 4, playlist: "Chill")
        let jsonWithPlaylist = String(data: try Output.encoder.encode(withPlaylist), encoding: .utf8)!
        XCTAssertEqual(jsonWithPlaylist, #"{"album":"Album","artist":"Artist","durationSeconds":180,"id":"t1","name":"Song","playlist":"Chill","rating":4}"#)
    }

    func testPlaylistInfoJSONSchema() throws {
        let playlist = PlaylistInfo(id: "p1", name: "Chill", trackCount: 12, kind: "user")
        let json = String(data: try Output.encoder.encode(playlist), encoding: .utf8)!
        XCTAssertEqual(json, #"{"id":"p1","kind":"user","name":"Chill","trackCount":12}"#)
    }

    func testPlayerStateJSONSchemaStopped() throws {
        let state = PlayerState(state: "stopped", volume: 50, track: nil, positionSeconds: nil)
        let json = String(data: try Output.encoder.encode(state), encoding: .utf8)!
        XCTAssertEqual(json, #"{"state":"stopped","volume":50}"#)
    }

    func testPlayerStateJSONSchemaWithTrack() throws {
        let track = TrackItem(id: "t1", name: "Song", artist: "Artist", album: "Album",
                              durationSeconds: 180, rating: 4, playlist: nil)
        let state = PlayerState(state: "playing", volume: 70, track: track, positionSeconds: 42)
        let json = String(data: try Output.encoder.encode(state), encoding: .utf8)!
        XCTAssertEqual(json, #"{"positionSeconds":42,"state":"playing","track":{"album":"Album","artist":"Artist","durationSeconds":180,"id":"t1","name":"Song","rating":4},"volume":70}"#)
    }

    func testTVItemJSONSchema() throws {
        let movie = TVItem(id: "tv1", name: "Movie Title", kind: "movie", show: nil,
                           seasonNumber: nil, episodeNumber: nil)
        let json = String(data: try Output.encoder.encode(movie), encoding: .utf8)!
        XCTAssertEqual(json, #"{"id":"tv1","kind":"movie","name":"Movie Title"}"#)

        let episode = TVItem(id: "tv2", name: "Ep Title", kind: "episode", show: "Show Name",
                             seasonNumber: 2, episodeNumber: 5)
        let episodeJSON = String(data: try Output.encoder.encode(episode), encoding: .utf8)!
        XCTAssertEqual(episodeJSON, #"{"episodeNumber":5,"id":"tv2","kind":"episode","name":"Ep Title","seasonNumber":2,"show":"Show Name"}"#)
    }

    func testShortcutInfoJSONSchema() throws {
        let noFolder = ShortcutInfo(id: "s1", name: "Do Thing", folder: nil)
        let json = String(data: try Output.encoder.encode(noFolder), encoding: .utf8)!
        XCTAssertEqual(json, #"{"id":"s1","name":"Do Thing"}"#)

        let withFolder = ShortcutInfo(id: "s2", name: "Do Thing 2", folder: "Utilities")
        let jsonWithFolder = String(data: try Output.encoder.encode(withFolder), encoding: .utf8)!
        XCTAssertEqual(jsonWithFolder, #"{"folder":"Utilities","id":"s2","name":"Do Thing 2"}"#)
    }

    func testHumanLines() {
        let track = TrackItem(id: "t1", name: "Song", artist: "Artist", album: "Album",
                              durationSeconds: 180, rating: 4, playlist: nil)
        XCTAssertEqual(track.humanLine, "t1  Song  Artist  Album")

        let playlist = PlaylistInfo(id: "p1", name: "Chill", trackCount: 12, kind: "user")
        XCTAssertEqual(playlist.humanLine, "p1  Chill  12 tracks  [user]")

        let stopped = PlayerState(state: "stopped", volume: 50, track: nil, positionSeconds: nil)
        XCTAssertEqual(stopped.humanLine, "stopped  vol 50")

        let playing = PlayerState(state: "playing", volume: 70, track: track, positionSeconds: 42)
        XCTAssertEqual(playing.humanLine, "playing  vol 70  Song — Artist")

        let movie = TVItem(id: "tv1", name: "Movie Title", kind: "movie", show: nil,
                           seasonNumber: nil, episodeNumber: nil)
        XCTAssertEqual(movie.humanLine, "tv1  Movie Title  (movie)")

        let episode = TVItem(id: "tv2", name: "Ep Title", kind: "episode", show: "Show Name",
                             seasonNumber: 2, episodeNumber: 5)
        XCTAssertEqual(episode.humanLine, "tv2  Ep Title  [Show Name]  (episode)")

        let noFolder = ShortcutInfo(id: "s1", name: "Do Thing", folder: nil)
        XCTAssertEqual(noFolder.humanLine, "s1  Do Thing")

        let withFolder = ShortcutInfo(id: "s2", name: "Do Thing 2", folder: "Utilities")
        XCTAssertEqual(withFolder.humanLine, "s2  Do Thing 2  [Utilities]")
    }
}
