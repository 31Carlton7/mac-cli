import Foundation

/// Builds the error thrown when `open(1)` exits non-zero. Deliberately a plain
/// NSError, not a MacError: a nonzero exit from the system opener is an
/// unexpected environment failure (no `open`, no handler registered, sandboxed
/// out, ...), not a validation problem the caller can fix by rephrasing input.
/// withErrorHandling's catch-all routes non-MacErrors to the "internal" JSON
/// envelope / plain "error: ..." line, which is the right shape here.
public func openFailure(status: Int32, url: URL) -> Error {
    NSError(
        domain: "Core",
        code: Int(status),
        userInfo: [NSLocalizedDescriptionKey: "open exited with status \(status) for '\(url.absoluteString)'."]
    )
}

/// Default opener: shells out to `/usr/bin/open` rather than linking AppKit's
/// NSWorkspace. NSWorkspace.shared.open expects a running application with an
/// event loop and an Info.plist-backed bundle identity; a plain command-line
/// executable doesn't reliably have either. `open(1)` is the same mechanism
/// macOS itself uses to hand a URL to its registered handler, and it works
/// from any CLI context without an AppKit dependency.
public func openViaSystemOpen(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw openFailure(status: process.terminationStatus, url: url)
    }
}
