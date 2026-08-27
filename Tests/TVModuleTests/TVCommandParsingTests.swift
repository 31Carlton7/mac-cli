import XCTest
@testable import TVModule

final class TVCommandParsingTests: XCTestCase {
    func testNowPauseResumeParse() {
        XCTAssertNoThrow(try TVCommand.parseAsRoot(["now"]))
        XCTAssertNoThrow(try TVCommand.parseAsRoot(["pause"]))
        XCTAssertNoThrow(try TVCommand.parseAsRoot(["resume"]))
    }

    func testListAcceptsOptionalLimitDefaultingTo50() throws {
        XCTAssertNoThrow(try TVCommand.parseAsRoot(["list"]))
        let list = try TVCommand.parseAsRoot(["list"]) as? TVCommand.List
        XCTAssertEqual(list?.limit, 50)
        let withLimit = try TVCommand.parseAsRoot(["list", "--limit", "5"]) as? TVCommand.List
        XCTAssertEqual(withLimit?.limit, 5)
    }

    func testPlayRequiresID() {
        XCTAssertThrowsError(try TVCommand.parseAsRoot(["play"]))
        XCTAssertNoThrow(try TVCommand.parseAsRoot(["play", "v1"]))
    }
}
