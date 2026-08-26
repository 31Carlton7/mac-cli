import XCTest
@testable import Core

final class AppleScriptRunnerTests: XCTestCase {
    func testEscape() {
        XCTAssertEqual(AppleScript.escape(#"say "hi""#), #"say \"hi\""#)
        XCTAssertEqual(AppleScript.escape(#"back\slash"#), #"back\\slash"#)
        XCTAssertEqual(AppleScript.escape("line1\nline2"), #"line1\nline2"#)
        XCTAssertEqual(AppleScript.escape("cr\rend"), #"cr\rend"#)
        XCTAssertEqual(AppleScript.escape(#"both \ and " here"#), #"both \\ and \" here"#)
    }

    func testParseRecords() {
        XCTAssertEqual(AppleScript.parseRecords(""), [])
        let one = "a\u{1F}b\u{1F}c"
        XCTAssertEqual(AppleScript.parseRecords(one), [["a", "b", "c"]])
        let two = "a\u{1F}b\u{1E}c\u{1F}d"
        XCTAssertEqual(AppleScript.parseRecords(two), [["a", "b"], ["c", "d"]])
    }

    @MainActor
    func testRunnerExecutesPlainScript() async throws {
        let result = try await AppleScript.run(#"return "ok""#, targetName: "Test")
        XCTAssertEqual(result, "ok")
    }

    func testMapErrorAutomationDenied() {
        let info: NSDictionary = [NSAppleScript.errorNumber: -1743,
                                  NSAppleScript.errorMessage: "Not authorized."]
        let error = AppleScript.mapError(info, targetName: "Mail")
        guard let mac = error as? MacError else { return XCTFail("expected MacError") }
        XCTAssertEqual(mac.code, .permissionDenied)
        XCTAssertTrue(mac.message.contains("Automation"))
        XCTAssertTrue(mac.message.contains("mac doctor"))
    }

    func testMapErrorTargetAppUnavailable() {
        for number in [-600, -10814] {
            let info: NSDictionary = [NSAppleScript.errorNumber: number,
                                      NSAppleScript.errorMessage: "Application isn't running."]
            let error = AppleScript.mapError(info, targetName: "Messages")
            guard let mac = error as? MacError else {
                return XCTFail("expected MacError for \(number)")
            }
            XCTAssertEqual(mac.code, .notFound)
            XCTAssertTrue(mac.message.contains("Messages"), "message: \(mac.message)")
        }
    }

    func testMapErrorUnknownStaysGeneric() {
        let info: NSDictionary = [NSAppleScript.errorNumber: -1728,
                                  NSAppleScript.errorMessage: "Can't get message."]
        let error = AppleScript.mapError(info, targetName: "Mail")
        XCTAssertFalse(error is MacError)
        XCTAssertTrue(error.localizedDescription.contains("Can't get message."))
    }
}
