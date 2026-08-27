import Core
import Foundation

public struct KeynoteActions {
    let store: KeynoteStore

    public init(store: KeynoteStore) {
        self.store = store
    }

    // MARK: - Docs

    public func docs() async throws -> [IWorkDocInfo] {
        try await store.docs()
    }

    public func newDoc(theme: String?, out: String?) async throws -> IWorkDocInfo {
        var canonicalTheme: String?
        if let theme {
            canonicalTheme = try await resolveTheme(theme)
        }
        let savePath = try out.map { try resolveOutputPath($0) }
        return try await store.newDoc(theme: canonicalTheme, savePath: savePath)
    }

    // MARK: - Slides

    public func addSlide(doc: String, title: String, body: String?) async throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else {
            throw MacError(.badInput, "Slide title cannot be empty.")
        }
        let info = try await resolveDoc(doc)
        try await store.addSlide(doc: info.name, title: trimmedTitle, body: body)
    }

    public func slides(doc: String) async throws -> [SlideInfo] {
        let info = try await resolveDoc(doc)
        return try await store.slides(doc: info.name)
    }

    // MARK: - Export

    public func export(doc: String, format: String, out: String, force: Bool) async throws -> String {
        let cooked = try cookedFormat(format, allowed: ["pdf", "pptx"])
        let info = try await resolveDoc(doc)
        let path = try resolveExportPath(out, force: force)
        try await store.export(doc: info.name, format: cooked, path: path)
        return path
    }

    // MARK: - Internals

    /// Resolves a theme case-insensitively against Keynote's theme list,
    /// returning the canonical name.
    func resolveTheme(_ name: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Theme name cannot be empty.")
        }
        let all = try await store.themes()
        guard let match = all.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            let listed = all
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .prefix(5).joined(separator: ", ")
            throw MacError(.notFound, "No theme named '\(trimmed)'. Available: \(listed).")
        }
        return match
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
            // Saved documents are named with their file extension ("live.key"),
            // so fall back to matching against names with the extension stripped.
            matches = all.filter {
                ($0.name as NSString).deletingPathExtension.caseInsensitiveCompare(trimmed) == .orderedSame
            }
        }
        if matches.isEmpty {
            throw MacError(.notFound, "No open document named '\(trimmed)'. Run: mac keynote docs")
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
