import Core
import Foundation

public final class AppleScriptFinderStore: FinderStore {
    public init() {}

    public func selection() async throws -> [FinderItem] {
        let out = try await AppleScript.run(FinderScripts.selection(), targetName: "Finder")
        return Self.parseItems(from: out)
    }

    public func reveal(path: String) async throws {
        _ = try await AppleScript.run(FinderScripts.reveal(path: path), targetName: "Finder")
    }

    public func open(path: String) async throws {
        _ = try await AppleScript.run(FinderScripts.open(path: path), targetName: "Finder")
    }

    public func trash(path: String) async throws {
        let out = try await AppleScript.run(FinderScripts.trash(path: path), targetName: "Finder")
        try Self.checkRefused(out)
    }

    public func disks() async throws -> [DiskInfo] {
        let out = try await AppleScript.run(FinderScripts.disks(), targetName: "Finder")
        return Self.parseDisks(from: out)
    }

    public func eject(name: String) async throws -> Bool {
        let out = try await AppleScript.run(FinderScripts.eject(name: name), targetName: "Finder")
        if out == "NOTFOUND" { return false }
        try Self.checkRefused(out)
        return out == "ok"
    }

    // MARK: - Parsing (static, unit-tested)

    /// FinderScripts' trash/eject wrap their verb in its own `try` and return
    /// "REFUSED:<message>" instead of letting a raw AppleScript error surface
    /// via the internal envelope — same shape as MusicModule's mutations.
    static func checkRefused(_ output: String) throws {
        guard output.hasPrefix("REFUSED:") else { return }
        let message = String(output.dropFirst("REFUSED:".count))
        throw MacError(.badInput, "Finder refused: \(message)")
    }

    /// Selection rows: POSIX path FS displayed name FS kind. Malformed rows
    /// (< 3 fields) are dropped with a warning; dedupe by path.
    static func parseItems(from output: String) -> [FinderItem] {
        let records = AppleScript.parseRecords(output)
        var seen = Set<String>()
        var malformed = 0
        let items = records.compactMap { fields -> FinderItem? in
            guard fields.count >= 3 else { malformed += 1; return nil }
            guard seen.insert(fields[0]).inserted else { return nil }
            return FinderItem(path: fields[0], name: fields[1], kind: fields[2])
        }
        warnIfDropped(malformed, noun: "item")
        return items
    }

    /// Disk rows: name FS capacityText FS freeText FS ejectableText.
    /// capacity/free are large reals emitted `as text` by the script — parsed
    /// via `Double` (handles both integer and scientific-notation text) then
    /// truncated to `Int`. Malformed rows (< 4 fields, or an unparseable
    /// capacity/free field) are dropped with a warning; dedupe by name.
    static func parseDisks(from output: String) -> [DiskInfo] {
        let records = AppleScript.parseRecords(output)
        var seen = Set<String>()
        var malformed = 0
        let disks = records.compactMap { fields -> DiskInfo? in
            guard fields.count >= 4, let capacity = Double(fields[1]), let free = Double(fields[2]) else {
                malformed += 1
                return nil
            }
            guard seen.insert(fields[0]).inserted else { return nil }
            return DiskInfo(name: fields[0], capacityBytes: Int(capacity), freeBytes: Int(free),
                            ejectable: fields[3] == "true")
        }
        warnIfDropped(malformed, noun: "disk")
        return disks
    }

    static func warnIfDropped(_ dropped: Int, noun: String) {
        if dropped > 0 {
            FileHandle.standardError.write(Data("warning: skipped \(dropped) unparseable \(noun) record(s)\n".utf8))
        }
    }
}
