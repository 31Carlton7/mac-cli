import Core
import Foundation
import XCTest
@testable import CallModule

final class CallCommandParsingTests: XCTestCase {
    func testCallRequiresNumber() {
        XCTAssertThrowsError(try CallCommand.parseAsRoot([]))
        XCTAssertNoThrow(try CallCommand.parseAsRoot(["+15551234567"]))
    }

    func testCallParsesNumberAndDryRunFlag() throws {
        let parsed = try CallCommand.parseAsRoot(["+1 555 123 4567", "--dry-run"]) as? CallCommand
        XCTAssertEqual(parsed?.number, "+1 555 123 4567")
        XCTAssertEqual(parsed?.dryRun, true)
    }

    func testFaceTimeRequiresHandle() {
        XCTAssertThrowsError(try FaceTimeCommand.parseAsRoot([]))
        XCTAssertNoThrow(try FaceTimeCommand.parseAsRoot(["user@example.com"]))
    }

    func testFaceTimeParsesHandleAndAudioFlag() throws {
        let parsed = try FaceTimeCommand.parseAsRoot(["user@example.com", "--audio", "--dry-run"]) as? FaceTimeCommand
        XCTAssertEqual(parsed?.handle, "user@example.com")
        XCTAssertEqual(parsed?.audio, true)
        XCTAssertEqual(parsed?.dryRun, true)
    }

    func testFaceTimeAudioDefaultsToFalse() throws {
        let parsed = try FaceTimeCommand.parseAsRoot(["user@example.com"]) as? FaceTimeCommand
        XCTAssertEqual(parsed?.audio, false)
        XCTAssertEqual(parsed?.dryRun, false)
    }

    // SAFETY: proves --dry-run never reaches the opener, so this suite can never place a
    // real call. The opener is captured and restored so no other test observes it.
    func testCallDryRunNeverInvokesOpener() async throws {
        var invoked = false
        let previousOpener = CallCommand.opener
        CallCommand.opener = { _ in invoked = true }
        defer { CallCommand.opener = previousOpener }

        let command = try CallCommand.parseAsRoot(["+15551234567", "--dry-run"]) as! CallCommand
        await command.run()

        XCTAssertFalse(invoked, "dry-run must never invoke the opener")
    }

    func testFaceTimeDryRunNeverInvokesOpener() async throws {
        var invoked = false
        let previousOpener = FaceTimeCommand.opener
        FaceTimeCommand.opener = { _ in invoked = true }
        defer { FaceTimeCommand.opener = previousOpener }

        let command = try FaceTimeCommand.parseAsRoot(["user@example.com", "--dry-run"]) as! FaceTimeCommand
        await command.run()

        XCTAssertFalse(invoked, "dry-run must never invoke the opener")
    }

    // SAFETY: proves the non-dry-run path DOES route through the injected opener (not some
    // other side effect), by capturing the URL it receives instead of ever opening it.
    func testCallNonDryRunInvokesInjectedOpenerWithTelURL() async throws {
        var capturedURL: URL?
        let previousOpener = CallCommand.opener
        CallCommand.opener = { url in capturedURL = url }
        defer { CallCommand.opener = previousOpener }

        let command = try CallCommand.parseAsRoot(["+15551234567"]) as! CallCommand
        await command.run()

        XCTAssertEqual(capturedURL?.absoluteString, "tel:+15551234567")
    }

    // Important-review fix: an `open` failure must surface through the "internal"
    // JSON envelope (a plain, non-MacError Error), not as a MacError badInput --
    // it's an environment failure, not a validation problem. withErrorHandling
    // calls exit() on any error, so this can't be exercised end-to-end through
    // command.run() without killing the test process; test the failure-building
    // function directly instead.
    func testOpenFailureIsNotAMacError() {
        let error = openFailure(status: 1, url: URL(string: "tel:+15551234567")!)
        XCTAssertFalse(error is MacError)
        XCTAssertTrue((error as NSError).localizedDescription.contains("tel:+15551234567"))
    }

    func testFaceTimeNonDryRunInvokesInjectedOpenerWithFaceTimeURL() async throws {
        var capturedURL: URL?
        let previousOpener = FaceTimeCommand.opener
        FaceTimeCommand.opener = { url in capturedURL = url }
        defer { FaceTimeCommand.opener = previousOpener }

        let command = try FaceTimeCommand.parseAsRoot(["user@example.com", "--audio"]) as! FaceTimeCommand
        await command.run()

        XCTAssertEqual(capturedURL?.absoluteString, "facetime-audio://user%40example.com")
    }
}
