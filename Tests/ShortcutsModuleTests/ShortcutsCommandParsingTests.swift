import XCTest
@testable import ShortcutsModule

final class ShortcutsCommandParsingTests: XCTestCase {
    func testRunRequiresNameOrID() {
        XCTAssertThrowsError(try ShortcutsCommand.parseAsRoot(["run"]))
        XCTAssertNoThrow(try ShortcutsCommand.parseAsRoot(["run", "Get Weather"]))
    }

    func testRunParsesInputAndIdFlag() throws {
        let parsed = try ShortcutsCommand.parseAsRoot(
            ["run", "1234ABCD", "--input", "hello", "--id"]
        ) as? ShortcutsCommand.Run
        XCTAssertEqual(parsed?.nameOrID, "1234ABCD")
        XCTAssertEqual(parsed?.input, "hello")
        XCTAssertEqual(parsed?.id, true)
    }

    func testRunDefaultsInputToNilAndIdFlagToFalse() throws {
        let parsed = try ShortcutsCommand.parseAsRoot(["run", "Get Weather"]) as? ShortcutsCommand.Run
        XCTAssertNil(parsed?.input)
        XCTAssertEqual(parsed?.id, false)
    }

    func testListAcceptsJSONFlag() throws {
        XCTAssertNoThrow(try ShortcutsCommand.parseAsRoot(["list"]))
        let parsed = try ShortcutsCommand.parseAsRoot(["list", "--json"]) as? ShortcutsCommand.List
        XCTAssertEqual(parsed?.output.json, true)
    }
}
