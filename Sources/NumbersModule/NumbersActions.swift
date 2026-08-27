import Core
import Foundation

public struct NumbersActions {
    let store: NumbersStore

    public init(store: NumbersStore) {
        self.store = store
    }

    // MARK: - Docs

    public func docs() async throws -> [IWorkDocInfo] {
        try await store.docs()
    }

    public func newDoc(out: String?) async throws -> IWorkDocInfo {
        let savePath = try out.map { try resolveOutputPath($0) }
        return try await store.newDoc(savePath: savePath)
    }

    // MARK: - Cells

    public func getCell(doc: String, sheet: Int, table: Int, cell: String) async throws -> String {
        let cooked = try cookedCellRef(cell, sheet: sheet, table: table)
        let info = try await resolveDoc(doc)
        return try await store.getCell(doc: info.name, sheet: sheet, table: table, cell: cooked)
    }

    public func setCell(doc: String, sheet: Int, table: Int, cell: String, value: String) async throws {
        let cooked = try cookedCellRef(cell, sheet: sheet, table: table)
        let info = try await resolveDoc(doc)
        try await store.setCell(doc: info.name, sheet: sheet, table: table, cell: cooked, value: value)
    }

    // MARK: - Export

    public func export(doc: String, format: String, out: String, force: Bool) async throws -> String {
        let cooked = try cookedFormat(format, allowed: ["pdf", "xlsx", "csv"])
        let info = try await resolveDoc(doc)
        let path = try resolveExportPath(out, force: force)
        try await store.export(doc: info.name, format: cooked, path: path)
        return path
    }

    // MARK: - Internals

    /// Validates 1-based sheet/table indexes and the A1-notation cell ref,
    /// returning the uppercased ref the store interpolates.
    func cookedCellRef(_ cell: String, sheet: Int, table: Int) throws -> String {
        guard sheet >= 1 else {
            throw MacError(.badInput, "--sheet must be >= 1.")
        }
        guard table >= 1 else {
            throw MacError(.badInput, "--table must be >= 1.")
        }
        guard cell.range(of: "^[A-Za-z]{1,3}[0-9]{1,7}$", options: .regularExpression) != nil else {
            throw MacError(.badInput, "Invalid cell reference '\(cell)'. Use A1 notation.")
        }
        return cell.uppercased()
    }

    /// Resolves an open document by exact case-insensitive name match
    /// (iWork documents expose no stable scripting id).
    func resolveDoc(_ name: String) async throws -> IWorkDocInfo {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Document name cannot be empty.")
        }
        let all = try await store.docs()
        let matches = all.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if matches.isEmpty {
            throw MacError(.notFound, "No open document named '\(trimmed)'. Run: mac numbers docs")
        }
        if matches.count > 1 {
            let candidates = matches.map(\.name)
                .sorted { $0 < $1 }
                .prefix(5).joined(separator: ", ")
            throw MacError(.badInput, "Multiple open documents named '\(trimmed)': \(candidates).")
        }
        return matches[0]
    }

    /// FinderActions-style resolve (trim, reject empty, expand `~`, absolutize)
    /// WITHOUT the exists-precheck on the file itself — the store writes it.
    /// The parent directory must already exist.
    func resolveOutputPath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Path cannot be empty.")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved = (expanded as NSString).isAbsolutePath
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        let parent = (resolved as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MacError(.notFound, "No directory at \(parent).")
        }
        return resolved
    }

    /// Export target resolution: overwriting an existing file requires --force.
    func resolveExportPath(_ path: String, force: Bool) throws -> String {
        let resolved = try resolveOutputPath(path)
        if FileManager.default.fileExists(atPath: resolved) && !force {
            throw MacError(.badInput, "File exists: \(resolved). Pass --force to overwrite.")
        }
        return resolved
    }

    /// Validates the export format against the allowed set and returns the
    /// cooked (lowercased) token the store expects.
    func cookedFormat(_ format: String, allowed: [String]) throws -> String {
        let cooked = format.trimmingCharacters(in: .whitespaces).lowercased()
        guard allowed.contains(cooked) else {
            throw MacError(.badInput, "Unknown format '\(format)'. Allowed: \(allowed.joined(separator: ", ")).")
        }
        return cooked
    }
}
