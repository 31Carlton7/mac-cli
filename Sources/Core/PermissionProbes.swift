import Foundation

public enum PermissionProbes {
    /// Maps an AEDeterminePermissionToAutomateTarget OSStatus to an AuthState.
    /// 0 granted; -1744 would-prompt and -600 target-not-running both mean
    /// consent hasn't been decided yet; anything else is denied.
    public static func automationState(fromStatus status: Int32) -> AuthState {
        switch status {
        case 0: .granted
        case -1744, -600: .notRequested
        default: .denied
        }
    }

    /// Full Disk Access has no query API; it is granted iff the protected path is readable.
    public static func fullDiskAccessState(probing path: String) -> AuthState {
        FileManager.default.isReadableFile(atPath: path) ? .granted : .denied
    }
}
