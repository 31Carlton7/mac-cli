import XCTest
import Core
@testable import ShortcutsModule

final class AppleScriptShortcutStoreTests: XCTestCase {
    let fs = AppleScript.fieldSep, rs = AppleScript.recordSep

    // MARK: - list row parsing (id FS name FS folderText)

    func testParsesRowsWithAndWithoutFolderDedupesAndSkipsMalformed() {
        let withFolder = ["s1", "Get Weather", "Utilities"].joined(separator: fs)
        let withoutFolder = ["s2", "Top Level", ""].joined(separator: fs)
        let duplicate = withFolder
        let output = [withFolder, withoutFolder, duplicate, "garbage"].joined(separator: rs)

        let items = AppleScriptShortcutStore.parseItems(from: output)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "s1")
        XCTAssertEqual(items[0].name, "Get Weather")
        XCTAssertEqual(items[0].folder, "Utilities")
        XCTAssertEqual(items[1].id, "s2")
        XCTAssertNil(items[1].folder)
    }

    func testEmptyOutputYieldsNoShortcuts() {
        XCTAssertTrue(AppleScriptShortcutStore.parseItems(from: "").isEmpty)
    }

    // MARK: - run: SHORTCUTERR mapping, SHORTCUTOUT: stripping, SHORTCUTNORESULT -> ""

    func testMapRunOutputThrowsBadInputCarryingMessageForShortcuterrPrefix() {
        XCTAssertThrowsError(try AppleScriptShortcutStore.mapRunOutput("SHORTCUTERR:no such shortcut")) { error in
            guard let macError = error as? MacError else { return XCTFail("wrong error type") }
            XCTAssertEqual(macError.code, .badInput)
            XCTAssertTrue(macError.message.contains("no such shortcut"))
        }
    }

    /// The critical collision case: a shortcut that genuinely returns the string
    /// "ok" must survive intact, not get swallowed as "no output". The
    /// "SHORTCUTOUT:" prefix is what makes this distinguishable from the
    /// "SHORTCUTNORESULT" sentinel.
    func testMapRunOutputStripsShortcutoutPrefixEvenWhenPayloadIsTheWordOk() throws {
        XCTAssertEqual(try AppleScriptShortcutStore.mapRunOutput("SHORTCUTOUT:ok"), "ok")
    }

    func testMapRunOutputMapsShortcutnoresultSentinelToEmptyString() throws {
        XCTAssertEqual(try AppleScriptShortcutStore.mapRunOutput("SHORTCUTNORESULT"), "")
    }

    func testMapRunOutputStripsShortcutoutPrefixForOrdinaryOutput() throws {
        XCTAssertEqual(try AppleScriptShortcutStore.mapRunOutput("SHORTCUTOUT:72F and sunny"), "72F and sunny")
    }

    /// Defensive: any output that doesn't match a known sentinel shape is passed
    /// through as-is rather than dropped, so a future script change can't
    /// silently regress into data loss.
    func testMapRunOutputPassesUnrecognizedOutputThroughUnchanged() throws {
        XCTAssertEqual(try AppleScriptShortcutStore.mapRunOutput("unexpected"), "unexpected")
    }
}
