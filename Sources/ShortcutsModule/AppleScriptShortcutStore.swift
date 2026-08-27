import Core
import Foundation

public final class AppleScriptShortcutStore: ShortcutStore {
    public init() {}

    public func list() async throws -> [ShortcutInfo] {
        let out = try await AppleScript.run(ShortcutScripts.list(), targetName: "Shortcuts Events")
        return Self.parseItems(from: out)
    }

    public func run(id: String, input: String?) async throws -> String {
        let out = try await AppleScript.run(ShortcutScripts.run(id: id, input: input), targetName: "Shortcuts Events")
        return try Self.mapRunOutput(out)
    }

    // MARK: - Parsing (static, unit-tested)

    /// Maps the run script's raw return value: "SHORTCUTERR:<message>" -> a
    /// thrown badInput carrying the message (the shortcut itself failed, or
    /// the id doesn't exist); "SHORTCUTNORESULT" (the script's fallback when
    /// the result couldn't be coerced to text) -> "" (no output);
    /// "SHORTCUTOUT:<payload>" -> the payload, stripped of its prefix -- this
    /// is what keeps a shortcut that genuinely returns the string "ok" from
    /// colliding with the no-output case. Anything else (defensive, should
    /// never happen given the script's shape) is passed through unchanged
    /// rather than dropped.
    static func mapRunOutput(_ output: String) throws -> String {
        if output.hasPrefix("SHORTCUTERR:") {
            let message = String(output.dropFirst("SHORTCUTERR:".count))
            throw MacError(.badInput, "Shortcut failed: \(message)")
        }
        if output == "SHORTCUTNORESULT" {
            return ""
        }
        if output.hasPrefix("SHORTCUTOUT:") {
            return String(output.dropFirst("SHORTCUTOUT:".count))
        }
        return output
    }

    /// Rows: id FS name FS folderText. Dedupe by id; malformed rows (< 3
    /// fields) are dropped with a warning, per the repo-wide convention.
    static func parseItems(from output: String) -> [ShortcutInfo] {
        let records = AppleScript.parseRecords(output)
        var seen = Set<String>()
        var malformed = 0
        let items = records.compactMap { fields -> ShortcutInfo? in
            guard fields.count >= 3 else { malformed += 1; return nil }
            guard seen.insert(fields[0]).inserted else { return nil }
            let folder = fields[2].isEmpty ? nil : fields[2]
            return ShortcutInfo(id: fields[0], name: fields[1], folder: folder)
        }
        warnIfDropped(malformed, noun: "shortcut")
        return items
    }

    static func warnIfDropped(_ dropped: Int, noun: String) {
        if dropped > 0 {
            FileHandle.standardError.write(Data("warning: skipped \(dropped) unparseable \(noun) record(s)\n".utf8))
        }
    }
}
