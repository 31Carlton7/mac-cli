import Foundation

public enum AuthState: String, Codable {
    case granted, denied, notRequested, writeOnly, unknown
}

public struct CapabilityStatus: Codable, Equatable, HumanRenderable {
    public let capability: String
    public let status: AuthState
    public let fix: String?

    public init(capability: String, status: AuthState, pane: String) {
        self.capability = capability
        self.status = status
        switch status {
        case .granted:
            self.fix = nil
        case .notRequested:
            self.fix = "Run any `mac \(capability)` command to trigger the macOS permission prompt."
        case .denied, .writeOnly:
            self.fix = "Enable full access in System Settings > Privacy & Security > \(pane) for your terminal app."
        case .unknown:
            self.fix = "Status could not be determined. Re-run mac doctor after using this capability once."
        }
    }

    /// For capabilities whose fix text doesn't follow the pane template.
    public init(capability: String, status: AuthState, fixOverride: String?) {
        self.capability = capability
        self.status = status
        self.fix = fixOverride
    }

    public var humanLine: String {
        "\(capability): \(status.rawValue)" + (fix.map { "  — \($0)" } ?? "")
    }
}
