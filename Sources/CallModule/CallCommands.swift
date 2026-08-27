import ArgumentParser
import Core
import Foundation

/// Default opener: shells out to `/usr/bin/open` rather than linking AppKit's
/// NSWorkspace. NSWorkspace.shared.open expects a running application with an
/// event loop and an Info.plist-backed bundle identity; a plain command-line
/// executable doesn't reliably have either. `open(1)` is the same mechanism
/// macOS itself uses to hand a URL to its registered handler, and it works
/// from any CLI context without an AppKit dependency.
func openViaSystemOpen(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw MacError(
            .badInput,
            "Failed to open '\(url.absoluteString)' (open exited with status \(process.terminationStatus))."
        )
    }
}

/// Shared dry-run/open/confirm behavior for CallCommand and FaceTimeCommand.
func openOrPrint(url: URL, dryRun: Bool, opener: (URL) throws -> Void, json: Bool, quiet: Bool) throws {
    if dryRun {
        Output.emitConfirmation(key: "url", value: url.absoluteString, human: "would open", json: json, quiet: quiet)
    } else {
        try opener(url)
        Output.emitConfirmation(key: "opening", value: url.absoluteString, human: "opening", json: json, quiet: quiet)
    }
}

public struct CallCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "call",
        abstract: "Open a tel: URL to start a phone call.",
        discussion: """
            Initiates a call via the system's tel: URL handler (FaceTime, or the \
            Phone app on a paired iPhone) -- mac-cli only opens the URL, macOS \
            still asks you to confirm before it actually dials.

            Examples:
              mac call "+1 555 123 4567"
              mac call 5551234567 --dry-run
            """
    )

    /// Overridable so tests can capture the URL instead of ever really opening one.
    public static var opener: (URL) throws -> Void = openViaSystemOpen

    @Argument(help: "Phone number to call. Digits, +, and ( ) - . spaces are accepted.")
    var number: String

    @Flag(help: "Print the tel: URL without opening it.")
    var dryRun = false

    @OptionGroup var output: OutputOptions

    public init() {}

    public func run() async {
        await withErrorHandling(json: output.json) {
            let url = try CallURLBuilder.telURL(number: number)
            try openOrPrint(url: url, dryRun: dryRun, opener: Self.opener, json: output.json, quiet: output.quiet)
        }
    }
}

public struct FaceTimeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "facetime",
        abstract: "Open a facetime: URL to start a FaceTime call.",
        discussion: """
            Initiates a FaceTime call via the system's facetime:/facetime-audio: URL \
            handler -- mac-cli only opens the URL, macOS still asks you to confirm \
            before it actually calls.

            Examples:
              mac facetime user@example.com
              mac facetime "+1 555 123 4567" --audio --dry-run
            """
    )

    /// Overridable so tests can capture the URL instead of ever really opening one.
    public static var opener: (URL) throws -> Void = openViaSystemOpen

    @Argument(help: "FaceTime handle: phone number or email address.")
    var handle: String

    @Flag(help: "Use FaceTime Audio instead of video.")
    var audio = false

    @Flag(help: "Print the facetime: URL without opening it.")
    var dryRun = false

    @OptionGroup var output: OutputOptions

    public init() {}

    public func run() async {
        await withErrorHandling(json: output.json) {
            let url = try CallURLBuilder.facetimeURL(handle: handle, audio: audio)
            try openOrPrint(url: url, dryRun: dryRun, opener: Self.opener, json: output.json, quiet: output.quiet)
        }
    }
}
