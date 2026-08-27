import XCTest
@testable import FinderModule

final class FinderCommandParsingTests: XCTestCase {
    func testSelectionAndDisksParseWithNoArguments() {
        XCTAssertNoThrow(try FinderCommand.parseAsRoot(["selection"]))
        XCTAssertNoThrow(try FinderCommand.parseAsRoot(["disks"]))
    }

    func testRevealOpenTrashRequirePath() throws {
        XCTAssertThrowsError(try FinderCommand.parseAsRoot(["reveal"]))
        XCTAssertThrowsError(try FinderCommand.parseAsRoot(["open"]))
        XCTAssertThrowsError(try FinderCommand.parseAsRoot(["trash"]))

        let reveal = try FinderCommand.parseAsRoot(["reveal", "/tmp/a.txt"]) as? FinderCommand.Reveal
        XCTAssertEqual(reveal?.path, "/tmp/a.txt")
        let open = try FinderCommand.parseAsRoot(["open", "/tmp/a.txt"]) as? FinderCommand.Open
        XCTAssertEqual(open?.path, "/tmp/a.txt")
        let trash = try FinderCommand.parseAsRoot(["trash", "/tmp/a.txt"]) as? FinderCommand.Trash
        XCTAssertEqual(trash?.path, "/tmp/a.txt")
    }

    func testEjectRequiresName() throws {
        XCTAssertThrowsError(try FinderCommand.parseAsRoot(["eject"]))
        let parsed = try FinderCommand.parseAsRoot(["eject", "Backup Drive"]) as? FinderCommand.Eject
        XCTAssertEqual(parsed?.name, "Backup Drive")
    }
}
