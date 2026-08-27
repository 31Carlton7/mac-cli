import Core
import Foundation

public struct PagesActions {
    let store: PagesStore

    public init(store: PagesStore) {
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

    // MARK: - Body text

    public func getBody(doc: String) async throws -> String {
        let info = try await resolveDoc(doc)
        return try await store.getBody(doc: info.name)
    }

    public func setBody(doc: String, text: String) async throws {
        try requireNonEmpty(text)
        let info = try await resolveDoc(doc)
        try await store.setBody(doc: info.name, text: text)
    }

    public func appendBody(doc: String, text: String) async throws {
        try requireNonEmpty(text)
        let info = try await resolveDoc(doc)
        try await store.appendBody(doc: info.name, text: text)
    }

    // MARK: - Export

    public func export(doc: String, format: String, out: String, force: Bool) async throws -> String {
        let cooked = try cookedFormat(format, allowed: ["pdf", "docx"])
        let info = try await resolveDoc(doc)
        let path = try resolveExportPath(out, force: force)
        try await store.export(doc: info.name, format: cooked, path: path)
        return path
    }

    // MARK: - Internals

    /// Rejects whitespace-only text but passes the original through — body
    /// text keeps its interior whitespace and newlines.
    func requireNonEmpty(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacError(.badInput, "Text cannot be empty.")
        }
    }

    /// Resolves an open document by exact case-insensitive name match
    /// (iWork documents expose no stable scripting id).
    func resolveDoc(_ name: String) async throws -> IWorkDocInfo {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Document name cannot be empty.")
        }
        let all = try await store.docs()
        var matches = all.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if matches.isEmpty {
            // Saved documents are named with their file extension ("letter.pages"),
            // so fall back to matching against names with the extension stripped.
            matches = all.filter {
                ($0.name as NSString).deletingPathExtension.caseInsensitiveCompare(trimmed) == .orderedSame
            }
        }
        if matches.isEmpty {
            throw MacError(.notFound, "No open document named '\(trimmed)'. Run: mac pages docs")
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
