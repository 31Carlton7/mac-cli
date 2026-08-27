import Core
import Foundation

public final class AppleScriptKeynoteStore: KeynoteStore {
    public init() {}

    public func docs() async throws -> [IWorkDocInfo] {
        let out = try await AppleScript.run(KeynoteScripts.docs(), targetName: "Keynote")
        return Self.parseDocs(from: out)
    }

    public func themes() async throws -> [String] {
        let out = try await AppleScript.run(KeynoteScripts.themes(), targetName: "Keynote")
        return Self.parseThemes(from: out)
    }

    public func newDoc(theme: String?, savePath: String?) async throws -> IWorkDocInfo {
        let out = try await AppleScript.run(KeynoteScripts.newDoc(theme: theme, savePath: savePath),
                                            targetName: "Keynote")
        try Self.checkRefused(out)
        guard let info = Self.parseDocs(from: out).first else {
            throw NSError(domain: "Keynote", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Keynote: created document but could not parse its record."])
        }
        return info
    }

    public func addSlide(doc: String, title: String, body: String?) async throws {
        let out = try await AppleScript.run(KeynoteScripts.addSlide(doc: doc, title: title, body: body),
                                            targetName: "Keynote")
        try Self.checkRefused(out)
    }

    public func slides(doc: String) async throws -> [SlideInfo] {
        let out = try await AppleScript.run(KeynoteScripts.slides(doc: doc), targetName: "Keynote")
        return Self.parseSlides(from: out)
    }

    public func export(doc: String, format: String, path: String) async throws {
        let out = try await AppleScript.run(KeynoteScripts.export(doc: doc, format: format, path: path),
                                            targetName: "Keynote")
        try Self.checkRefused(out)
    }

    // MARK: - Parsing (static, unit-tested)

    /// KeynoteScripts wraps mutation/export verbs in their own `try` and
    /// returns "REFUSED:<message>" instead of letting a raw AppleScript error
    /// surface via the internal envelope — same shape as Music/Finder.
    static func checkRefused(_ output: String) throws {
        guard output.hasPrefix("REFUSED:") else { return }
        let message = String(output.dropFirst("REFUSED:".count))
        throw MacError(.badInput, "Keynote refused: \(message)")
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

    /// Slide rows: slideNumber FS titleOrEmpty. Malformed rows (< 2 fields,
    /// or an unparseable slide number) are dropped with a warning.
    static func parseSlides(from output: String) -> [SlideInfo] {
        let records = AppleScript.parseRecords(output)
        var malformed = 0
        let slides = records.compactMap { fields -> SlideInfo? in
            guard fields.count >= 2, let number = Int(fields[0]) else { malformed += 1; return nil }
            return SlideInfo(number: number, title: fields[1])
        }
        warnIfDropped(malformed, noun: "slide")
        return slides
    }

    /// Theme rows are single-field records (just the name).
    static func parseThemes(from output: String) -> [String] {
        guard !output.isEmpty else { return [] }
        return output.components(separatedBy: AppleScript.recordSep)
    }

    static func warnIfDropped(_ dropped: Int, noun: String) {
        if dropped > 0 {
            FileHandle.standardError.write(Data("warning: skipped \(dropped) unparseable \(noun) record(s)\n".utf8))
        }
    }
}
