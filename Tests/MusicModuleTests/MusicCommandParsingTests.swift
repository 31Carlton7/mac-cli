import XCTest
@testable import MusicModule

final class MusicCommandParsingTests: XCTestCase {
    func testPlayParsesPlaylistAndTrackIDOptions() throws {
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["play"]))
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["play", "--playlist", "Workout"]))
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["play", "--track-id", "t1", "--json"]))
    }

    func testVolumeAcceptsOptionalPositionalLevel() {
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["volume"]))
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["volume", "50"]))
    }

    func testSearchRequiresQuery() {
        XCTAssertThrowsError(try MusicCommand.parseAsRoot(["search"]))
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["search", "brunch", "--limit", "5"]))
    }

    func testRateRequiresTrackIDAndStars() {
        XCTAssertThrowsError(try MusicCommand.parseAsRoot(["rate", "t1"]))
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["rate", "t1", "3"]))
    }

    func testPlaylistSubcommandsParseKebabNames() {
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["playlist-create", "Road Trip"]))
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["playlist-add", "Road Trip", "t1"]))
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["playlist-remove", "Road Trip", "t1"]))
        XCTAssertNoThrow(try MusicCommand.parseAsRoot(["playlist-delete", "Road Trip"]))
    }
}
