import XCTest
@testable import Core

final class FinderModelsTests: XCTestCase {
    func testFinderItemJSONSchema() throws {
        let item = FinderItem(path: "/Users/x/file.txt", name: "file.txt", kind: "Plain Text Document")
        let json = String(data: try Output.encoder.encode(item), encoding: .utf8)!
        XCTAssertEqual(json, #"{"kind":"Plain Text Document","name":"file.txt","path":"\/Users\/x\/file.txt"}"#)
    }

    func testDiskInfoJSONSchema() throws {
        let disk = DiskInfo(name: "Macintosh HD", capacityBytes: 500_000_000_000, freeBytes: 100_000_000_000, ejectable: false)
        let json = String(data: try Output.encoder.encode(disk), encoding: .utf8)!
        XCTAssertEqual(json, #"{"capacityBytes":500000000000,"ejectable":false,"freeBytes":100000000000,"name":"Macintosh HD"}"#)
    }

    func testFinderItemHumanLine() {
        let item = FinderItem(path: "/Users/x/file.txt", name: "file.txt", kind: "Plain Text Document")
        XCTAssertEqual(item.humanLine, "/Users/x/file.txt  (Plain Text Document)")
    }

    func testDiskInfoHumanLineNotEjectable() {
        let disk = DiskInfo(name: "Macintosh HD", capacityBytes: 1_073_741_824 * 500,
                            freeBytes: 1_073_741_824 * 100, ejectable: false)
        XCTAssertEqual(disk.humanLine, "Macintosh HD  100G free of 500G")
    }

    func testDiskInfoHumanLineEjectable() {
        let disk = DiskInfo(name: "USB Drive", capacityBytes: 1_073_741_824 * 32,
                            freeBytes: 1_073_741_824 * 10, ejectable: true)
        XCTAssertEqual(disk.humanLine, "USB Drive  10G free of 32G  [ejectable]")
    }
}
