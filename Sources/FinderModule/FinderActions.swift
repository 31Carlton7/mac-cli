import Core
import Foundation

public struct FinderActions {
    let store: FinderStore

    public init(store: FinderStore) {
        self.store = store
    }

    // MARK: - Selection / disks

    public func selection() async throws -> [FinderItem] {
        try await store.selection()
    }

    public func disks() async throws -> [DiskInfo] {
        try await store.disks()
    }

    // MARK: - File operations

    public func reveal(path: String) async throws {
        let resolved = try resolve(path: path)
        try await store.reveal(path: resolved)
    }

    public func open(path: String) async throws {
        let resolved = try resolve(path: path)
        try await store.open(path: resolved)
    }

    public func trash(path: String) async throws {
        let resolved = try resolve(path: path)
        try await store.trash(path: resolved)
    }

    // MARK: - Eject

    public func eject(name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Disk name cannot be empty.")
        }
        let all = try await store.disks()
        guard let match = all.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw MacError(.notFound, "No disk named '\(trimmed)'. Run: mac finder disks")
        }
        guard match.ejectable else {
            throw MacError(.badInput, "'\(match.name)' is not ejectable.")
        }
        guard try await store.eject(name: match.name) else {
            throw MacError(.notFound, "No disk named '\(match.name)'. Run: mac finder disks")
        }
    }

    // MARK: - Internals

    /// Trims, rejects empty, expands `~`, makes the path absolute against the current
    /// working directory, and confirms something exists there.
    func resolve(path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Path cannot be empty.")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved = (expanded as NSString).isAbsolutePath
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw MacError(.notFound, "No file or folder at \(resolved).")
        }
        return resolved
    }
}
