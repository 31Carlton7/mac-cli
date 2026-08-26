import XCTest
@testable import Core

final class PermissionProbesTests: XCTestCase {
    func testAutomationStateMapping() {
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: 0), .granted)
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: -1744), .notRequested) // would prompt
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: -600), .unknown)  // app not running, indeterminate
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: -1743), .denied)
    }

    func testFullDiskAccessProbe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cli-fda-test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let readable = dir.appendingPathComponent("chat.db")
        try Data("x".utf8).write(to: readable)
        XCTAssertEqual(PermissionProbes.fullDiskAccessState(probing: readable.path), .granted)

        // Path doesn't exist at all: can't distinguish "no Messages setup" from a TCC-blocked stat.
        XCTAssertEqual(PermissionProbes.fullDiskAccessState(probing: dir.appendingPathComponent("missing.db").path), .unknown)

        // Path exists but is unreadable: a real denial.
        let unreadable = dir.appendingPathComponent("locked.db")
        try Data("x".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        if FileManager.default.isReadableFile(atPath: unreadable.path) {
            // Running as root (or similar) can bypass POSIX permissions entirely, making
            // chmod 000 still readable. In that environment this case can't be exercised.
            throw XCTSkip("process can read despite chmod 000 (likely running as root); denied case not exercisable")
        }
        XCTAssertEqual(PermissionProbes.fullDiskAccessState(probing: unreadable.path), .denied)
    }

    func testCapabilityStatusFixOverride() throws {
        let status = CapabilityStatus(capability: "automation:Mail", status: .denied,
                                      fixOverride: "Enable Mail under Automation.")
        XCTAssertEqual(status.fix, "Enable Mail under Automation.")
        XCTAssertEqual(status.humanLine, "automation:Mail: denied  — Enable Mail under Automation.")
        let granted = CapabilityStatus(capability: "fullDiskAccess", status: .granted, fixOverride: nil)
        let json = String(data: try Output.encoder.encode(granted), encoding: .utf8)!
        XCTAssertEqual(json, #"{"capability":"fullDiskAccess","status":"granted"}"#)
    }
}
