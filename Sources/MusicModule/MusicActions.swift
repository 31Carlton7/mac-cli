import Core
import Foundation

public struct MusicActions {
    let store: MusicStore

    public init(store: MusicStore) {
        self.store = store
    }

    // MARK: - Transport

    public func now() async throws -> PlayerState {
        try await store.playerState()
    }

    public func play(playlist: String?, trackID: String?) async throws {
        if playlist == nil && trackID == nil {
            try await store.resume()
            return
        }
        if playlist != nil && trackID != nil {
            throw MacError(.badInput, "Pass --playlist or --track-id, not both.")
        }
        if let playlist {
            let info = try await resolvePlaylist(playlist)
            guard try await store.playPlaylist(id: info.id) else {
                throw MacError(.notFound, "No playlist named '\(playlist)'. Run: mac music playlists")
            }
            return
        }
        if let trackID {
            guard try await store.playTrack(id: trackID) else {
                throw MacError(.notFound, "No track with id \(trackID). Run: mac music search")
            }
        }
    }

    public func pause() async throws { try await store.pause() }
    public func next() async throws { try await store.next() }
    public func previous() async throws { try await store.previous() }

    public func volume(_ level: Int?) async throws -> Int {
        guard let level else {
            return try await store.playerState().volume
        }
        guard (0...100).contains(level) else {
            throw MacError(.badInput, "--volume must be between 0 and 100.")
        }
        try await store.setVolume(level)
        return level
    }

    // MARK: - Search

    public func search(query: String, limit: Int) async throws -> [TrackItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Search query cannot be empty.")
        }
        guard (1...200).contains(limit) else {
            throw MacError(.badInput, "--limit must be between 1 and 200.")
        }
        return try await store.search(trimmed, limit: limit)
    }

    // MARK: - Playlists

    public func playlists() async throws -> [PlaylistInfo] {
        try await store.playlists()
    }

    public func playlistCreate(name: String) async throws -> PlaylistInfo {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacError(.badInput, "Playlist name cannot be empty.")
        }
        let all = try await store.playlists()
        if all.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw MacError(.badInput, "A playlist named '\(trimmed)' already exists.")
        }
        return try await store.createPlaylist(name: trimmed)
    }

    public func playlistAdd(playlist: String, trackID: String) async throws {
        let info = try await resolvePlaylist(playlist)
        try requireUserPlaylist(info)
        guard try await store.addTrack(id: trackID, toPlaylist: info.id) else {
            throw MacError(.notFound, "No track with id \(trackID). Run: mac music search")
        }
    }

    public func playlistRemove(playlist: String, trackID: String) async throws {
        let info = try await resolvePlaylist(playlist)
        try requireUserPlaylist(info)
        guard try await store.removeTrack(id: trackID, fromPlaylist: info.id) else {
            throw MacError(.notFound, "No track with id \(trackID). Run: mac music search")
        }
    }

    public func playlistDelete(name: String) async throws {
        let info = try await resolvePlaylist(name)
        try requireUserPlaylist(info)
        guard try await store.deletePlaylist(id: info.id) else {
            throw MacError(.notFound, "No playlist named '\(name)'. Run: mac music playlists")
        }
    }

    // MARK: - Rating

    public func rate(trackID: String, stars: Int) async throws {
        guard (0...5).contains(stars) else {
            throw MacError(.badInput, "--stars must be between 0 and 5.")
        }
        guard try await store.rate(trackID: trackID, rating0to100: stars * 20) else {
            throw MacError(.notFound, "No track with id \(trackID). Run: mac music search")
        }
    }

    // MARK: - Internals

    /// Resolves a playlist by exact id first, then by case-insensitive name.
    func resolvePlaylist(_ nameOrID: String) async throws -> PlaylistInfo {
        let all = try await store.playlists()
        if let exact = all.first(where: { $0.id == nameOrID }) {
            return exact
        }
        let matches = all.filter { $0.name.caseInsensitiveCompare(nameOrID) == .orderedSame }
        if matches.isEmpty {
            throw MacError(.notFound, "No playlist named '\(nameOrID)'. Run: mac music playlists")
        }
        if matches.count > 1 {
            // Sort name-then-id before capping so the candidate list is deterministic
            // regardless of store insertion order (repo-wide "sorted capped-5" convention).
            let sorted = matches.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    || ($0.name.caseInsensitiveCompare($1.name) == .orderedSame && $0.id < $1.id)
            }
            let candidates = sorted.prefix(5).map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
            throw MacError(.badInput, "Multiple playlists named '\(nameOrID)': \(candidates). Use the id from: mac music playlists")
        }
        return matches[0]
    }

    func requireUserPlaylist(_ info: PlaylistInfo) throws {
        // Store contract emits cooked "user"/"system" values, but this guards against drift.
        guard info.kind.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("user") == .orderedSame else {
            throw MacError(.badInput, "'\(info.name)' is a system playlist — only user playlists can be modified.")
        }
    }
}
