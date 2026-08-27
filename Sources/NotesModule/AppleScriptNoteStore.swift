import Core
import Foundation

public final class AppleScriptNoteStore: NoteStore {
    public init() {}

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        // NoteScripts.isoDate emits local wall-clock with no offset; parse in the same zone.
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    public func folders() async throws -> [NoteFolderInfo] {
        let out = try await AppleScript.run(NoteScripts.folders(), targetName: "Notes")
        return Self.folderInfos(from: out)
    }

    public func notes(folderID: String?) async throws -> [NoteItem] {
        let out = try await AppleScript.run(NoteScripts.notes(folderID: folderID, includeBodies: false), targetName: "Notes")
        return Self.items(from: out)
    }

    public func searchRows(folderID: String?) async throws -> [NoteSearchRow] {
        let out = try await AppleScript.run(NoteScripts.notes(folderID: folderID, includeBodies: true), targetName: "Notes")
        return Self.parseSearchRows(from: out)
    }

    public func read(id: String, html: Bool) async throws -> NoteItem? {
        let out = try await AppleScript.run(NoteScripts.read(id: id, html: html), targetName: "Notes")
        if out == "NOTFOUND" { return nil }
        return Self.items(from: out, bodyField: true).first
    }

    public func add(title: String, body: String, folderID: String?) async throws -> NoteItem {
        let out = try await AppleScript.run(NoteScripts.add(title: title, body: body, folderID: folderID), targetName: "Notes")
        if out == "NOTFOUND" {
            throw MacError(.notFound, "Target folder no longer exists. Run: mac notes folders")
        }
        guard let item = Self.items(from: out).first else {
            throw NSError(domain: "Notes", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Notes: created note but could not parse its record."])
        }
        return item
    }

    public func append(id: String, text: String) async throws -> Bool {
        try await AppleScript.run(NoteScripts.append(id: id, text: text), targetName: "Notes") != "NOTFOUND"
    }

    public func edit(id: String, title: String?, body: String?) async throws -> Bool {
        try await AppleScript.run(NoteScripts.edit(id: id, title: title, body: body), targetName: "Notes") != "NOTFOUND"
    }

    public func delete(id: String) async throws -> Bool {
        try await AppleScript.run(NoteScripts.delete(id: id), targetName: "Notes") != "NOTFOUND"
    }

    // MARK: - Parsing (static, unit-tested)

    static func items(from output: String, bodyField: Bool = false) -> [NoteItem] {
        let records = AppleScript.parseRecords(output)
        let items = records.compactMap { fields -> NoteItem? in
            guard fields.count >= 6 else { return nil }
            return NoteItem(id: fields[0], title: fields[1], folder: fields[2], account: fields[3],
                            created: dateFormatter.date(from: fields[4]) ?? Date(timeIntervalSince1970: 0),
                            modified: dateFormatter.date(from: fields[5]) ?? Date(timeIntervalSince1970: 0),
                            body: bodyField && fields.count >= 7 ? fields[6] : nil)
        }
        warnIfDropped(records.count - items.count, noun: "note")
        return items
    }

    static func parseSearchRows(from output: String) -> [NoteSearchRow] {
        let records = AppleScript.parseRecords(output)
        let rows = records.compactMap { fields -> NoteSearchRow? in
            guard fields.count >= 7 else { return nil }
            let item = NoteItem(id: fields[0], title: fields[1], folder: fields[2], account: fields[3],
                                created: dateFormatter.date(from: fields[4]) ?? Date(timeIntervalSince1970: 0),
                                modified: dateFormatter.date(from: fields[5]) ?? Date(timeIntervalSince1970: 0),
                                body: nil)
            return NoteSearchRow(item: item, text: fields[6])
        }
        warnIfDropped(records.count - rows.count, noun: "note")
        return rows
    }

    static func folderInfos(from output: String) -> [NoteFolderInfo] {
        let records = AppleScript.parseRecords(output)
        let folders = records.compactMap { fields -> NoteFolderInfo? in
            guard fields.count >= 4, let count = Int(fields[3]) else { return nil }
            return NoteFolderInfo(id: fields[0], name: fields[1], account: fields[2], noteCount: count)
        }
        warnIfDropped(records.count - folders.count, noun: "folder")
        return folders
    }

    static func warnIfDropped(_ dropped: Int, noun: String) {
        if dropped > 0 {
            FileHandle.standardError.write(Data("warning: skipped \(dropped) unparseable \(noun) record(s)\n".utf8))
        }
    }
}
