import XCTest
import Core
@testable import FinderModule

final class AppleScriptFinderStoreTests: XCTestCase {
    let fs = AppleScript.fieldSep, rs = AppleScript.recordSep

    // MARK: - Selection parsing

    func testParsesSelectionRows() {
        let row = ["/Users/x/a.txt", "a.txt", "Plain Text Document"].joined(separator: fs)
        let items = AppleScriptFinderStore.parseItems(from: row)
        XCTAssertEqual(items, [FinderItem(path: "/Users/x/a.txt", name: "a.txt", kind: "Plain Text Document")])
    }

    func testEmptySelectionYieldsNothing() {
        XCTAssertTrue(AppleScriptFinderStore.parseItems(from: "").isEmpty)
    }

    func testSelectionRowsDedupeByPathAndDropMalformed() {
        let row = ["/Users/x/a.txt", "a.txt", "Plain Text Document"].joined(separator: fs)
        let output = [row, row, "garbage"].joined(separator: rs)
        let items = AppleScriptFinderStore.parseItems(from: output)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].path, "/Users/x/a.txt")
    }

    // MARK: - Disk parsing (Double -> Int for capacity/free)

    func testParsesDiskRowWithLargeCapacityAndFreeSpace() {
        let row = ["Macintosh HD", "500000000000", "100000000000", "false"].joined(separator: fs)
        let disks = AppleScriptFinderStore.parseDisks(from: row)
        XCTAssertEqual(disks, [DiskInfo(name: "Macintosh HD", capacityBytes: 500_000_000_000,
                                        freeBytes: 100_000_000_000, ejectable: false)])
    }

    /// Finder emits capacity/free space `as text` on large reals, which can
    /// surface in scientific notation (e.g. "5.0E+11") -- Double parses both
    /// forms; the store truncates to Int.
    func testParsesDiskRowWithScientificNotationCapacity() {
        let row = ["Big Disk", "5.0E+11", "1.0E+11", "true"].joined(separator: fs)
        let disks = AppleScriptFinderStore.parseDisks(from: row)
        XCTAssertEqual(disks.first?.capacityBytes, 500_000_000_000)
        XCTAssertEqual(disks.first?.freeBytes, 100_000_000_000)
        XCTAssertEqual(disks.first?.ejectable, true)
    }

    func testDiskRowsDedupeByNameAndDropMalformed() {
        let row = ["Macintosh HD", "500", "100", "false"].joined(separator: fs)
        let output = [row, row, "garbage"].joined(separator: rs)
        let disks = AppleScriptFinderStore.parseDisks(from: output)
        XCTAssertEqual(disks.count, 1)
    }

    // MARK: - REFUSED mapping (trash / eject)

    func testCheckRefusedThrowsBadInputWithMessage() {
        XCTAssertThrowsError(try AppleScriptFinderStore.checkRefused("REFUSED:Access denied.")) { error in
            guard let macError = error as? MacError else { return XCTFail("wrong error type") }
            XCTAssertEqual(macError.code, .badInput)
            XCTAssertTrue(macError.message.contains("Finder refused: Access denied."))
        }
    }

    func testCheckRefusedDoesNothingForOtherOutputs() {
        XCTAssertNoThrow(try AppleScriptFinderStore.checkRefused("ok"))
        XCTAssertNoThrow(try AppleScriptFinderStore.checkRefused("NOTFOUND"))
    }
}
