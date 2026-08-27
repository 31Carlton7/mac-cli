import Core
import Foundation

public final class AppleScriptPagesStore: PagesStore {
    public init() {}

    public func docs() async throws -> [IWorkDocInfo] {
        let out = try await AppleScript.run(PagesScripts.docs(), targetName: "Pages")
        return Self.parseDocs(from: out)
    }

    public func newDoc(savePath: String?) async throws -> IWorkDocInfo {
        let out = try await AppleScript.run(PagesScripts.newDoc(savePath: savePath),
                                            targetName: "Pages")
        try Self.checkRefused(out)
        guard let info = Self.parseDocs(from: out).first else {
            throw NSError(domain: "Pages", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Pages: created document but could not parse its record."])
        }
        return info
    }

    public func getBody(doc: String) async throws -> String {
        let out = try await AppleScript.run(PagesScripts.getBody(doc: doc), targetName: "Pages")
        try Self.checkRefused(out)
        // Payload, not records — body text passes through verbatim.
        return out
    }

    public func setBody(doc: String, text: String) async throws {
        let out = try await AppleScript.run(PagesScripts.setBody(doc: doc, text: text),
                                            targetName: "Pages")
        try Self.checkRefused(out)
    }

    public func appendBody(doc: String, text: String) async throws {
        let out = try await AppleScript.run(PagesScripts.appendBody(doc: doc, text: text),
                                            targetName: "Pages")
        try Self.checkRefused(out)
    }

    public func export(doc: String, format: String, path: String) async throws {
        let out = try await AppleScript.run(PagesScripts.export(doc: doc, format: format, path: path),
                                            targetName: "Pages")
        try Self.checkRefused(out)
    }

    // MARK: - Parsing (static, unit-tested)

    /// PagesScripts wraps body/export verbs in their own `try` and returns
    /// "REFUSED:<message>" instead of letting a raw AppleScript error surface
    /// via the internal envelope — same shape as Keynote/Music/Finder.
    static func checkRefused(_ output: String) throws {
        guard output.hasPrefix("REFUSED:") else { return }
        let message = String(output.dropFirst("REFUSED:".count))
        throw MacError(.badInput, "Pages refused: \(message)")
    }

    /// Doc rows: name FS pathOrEmpty FS modifiedText. Empty path -> nil
    /// (never saved). Duplicate names are PRESERVED — the actions layer's
    /// ambiguity rejection needs to see them. Malformed rows (< 3 fields)
    /// are dropped with a warning.
    static func parseDocs(from output: String) -> [IWorkDocInfo] {
        let records = AppleScript.parseRecords(output)
        var malformed = 0
        let docs = records.compactMap { fields -> IWorkDocInfo? in
            guard fields.count >= 3 else { malformed += 1; return nil }
            return IWorkDocInfo(name: fields[0],
                                path: fields[1].isEmpty ? nil : fields[1],
                                modified: fields[2] == "true")
        }
        warnIfDropped(malformed, noun: "document")
        return docs
    }

    static func warnIfDropped(_ dropped: Int, noun: String) {
        if dropped > 0 {
            FileHandle.standardError.write(Data("warning: skipped \(dropped) unparseable \(noun) record(s)\n".utf8))
        }
    }
}
