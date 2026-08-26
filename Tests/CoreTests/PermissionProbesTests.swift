import XCTest
@testable import Core

final class PermissionProbesTests: XCTestCase {
    func testAutomationStateMapping() {
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: 0), .granted)
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: -1744), .notRequested) // would prompt
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: -600), .notRequested)  // app not running
        XCTAssertEqual(PermissionProbes.automationState(fromStatus: -1743), .denied)
    }

    func testFullDiskAccessProbe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cli-fda-test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let readable = dir.appendingPathComponent("chat.db")
        try Data("x".utf8).write(to: readable)
        XCTAssertEqual(PermissionProbes.fullDiskAccessState(probing: readable.path), .granted)
        XCTAssertEqual(PermissionProbes.fullDiskAccessState(probing: dir.appendingPathComponent("missing.db").path), .denied)
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
