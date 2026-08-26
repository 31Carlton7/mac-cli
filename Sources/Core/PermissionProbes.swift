import Foundation

public enum PermissionProbes {
    /// Maps an AEDeterminePermissionToAutomateTarget OSStatus to an AuthState.
    /// 0 means granted; -1744 means the call would prompt, i.e. consent hasn't
    /// been decided yet. -600 means the target app isn't running — the target
    /// must be running for AEDeterminePermission to report a real decision, so
    /// that result is indeterminate rather than "never asked". Anything else
    /// is a real denial.
    public static func automationState(fromStatus status: Int32) -> AuthState {
        switch status {
        case 0: .granted
        case -1744: .notRequested
        case -600: .unknown
        default: .denied
        }
    }

    /// Full Disk Access has no query API; it is probed via a protected path.
    /// Readable means granted. If the path doesn't exist at all, that's
    /// ambiguous — TCC can block the stat itself, and the path may genuinely
    /// never have been created (e.g. Messages never used on this Mac) — so
    /// that case is unknown rather than denied. Only a path that exists but
    /// can't be read is a real denial.
    public static func fullDiskAccessState(probing path: String) -> AuthState {
        if FileManager.default.isReadableFile(atPath: path) { return .granted }
        return FileManager.default.fileExists(atPath: path) ? .denied : .unknown
    }
}
