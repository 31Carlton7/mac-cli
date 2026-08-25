import XCTest
@testable import Core

final class MacErrorTests: XCTestCase {
    func testExitCodes() {
        XCTAssertEqual(MacError(.notFound, "x").exitCode, 1)
        XCTAssertEqual(MacError(.badInput, "x").exitCode, 1)
        XCTAssertEqual(MacError(.permissionDenied, "x").exitCode, 2)
    }

    func testJSONShape() {
        let err = MacError(.permissionDenied, "Calendar access not granted. Run: mac doctor")
        XCTAssertEqual(
            err.jsonString,
            #"{"error":{"code":"permissionDenied","message":"Calendar access not granted. Run: mac doctor"}}"# + "\n"
        )
    }

    func testInternalJSONShape() {
        XCTAssertEqual(
            MacError.internalJSONString("boom"),
            #"{"error":{"code":"internal","message":"boom"}}"# + "\n"
        )
    }
}
