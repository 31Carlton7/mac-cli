import Core
import Foundation

public final class AppleScriptMusicStore: MusicStore {
    public init() {}

    public func playerState() async throws -> PlayerState {
        let out = try await AppleScript.run(MusicScripts.playerState(), targetName: "Music")
        return Self.parsePlayerState(from: out)
    }

    public func resume() async throws {
        _ = try await AppleScript.run(MusicScripts.resume(), targetName: "Music")
    }

    public func pause() async throws {
        _ = try await AppleScript.run(MusicScripts.pause(), targetName: "Music")
    }

    public func next() async throws {
        _ = try await AppleScript.run(MusicScripts.next(), targetName: "Music")
    }

    public func previous() async throws {
        _ = try await AppleScript.run(MusicScripts.previous(), targetName: "Music")
    }

    public func setVolume(_ volume: Int) async throws {
        _ = try await AppleScript.run(MusicScripts.setVolume(volume), targetName: "Music")
    }

    public func playPlaylist(id: String) async throws -> Bool {
        let out = try await AppleScript.run(MusicScripts.playPlaylist(id: id), targetName: "Music")
        try Self.checkTimeout(out)
        return out == "ok"
    }

    public func playTrack(id: String) async throws -> Bool {
        let out = try await AppleScript.run(MusicScripts.playTrack(id: id), targetName: "Music")
        try Self.checkTimeout(out)
        return out == "ok"
    }

    public func search(_ query: String, limit: Int) async throws -> [TrackItem] {
        let out = try await AppleScript.run(MusicScripts.search(query: query, limit: limit), targetName: "Music")
        return Self.parseTracks(from: out)
    }

    public func playlists() async throws -> [PlaylistInfo] {
        let out = try await AppleScript.run(MusicScripts.playlists(), targetName: "Music")
        return Self.parsePlaylists(from: out)
    }

    public func createPlaylist(name: String) async throws -> PlaylistInfo {
        let out = try await AppleScript.run(MusicScripts.createPlaylist(name: name), targetName: "Music")
        guard let info = Self.parsePlaylists(from: out).first else {
            throw NSError(domain: "Music", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Music: created playlist but could not parse its record."])
        }
        return info
    }

    public func addTrack(id: String, toPlaylist playlistID: String) async throws -> Bool {
        let out = try await AppleScript.run(MusicScripts.addTrack(id: id, toPlaylist: playlistID), targetName: "Music")
        try Self.checkTimeout(out)
        try Self.checkRefused(out)
        return out == "ok"
    }

    public func removeTrack(id: String, fromPlaylist playlistID: String) async throws -> Bool {
        let out = try await AppleScript.run(MusicScripts.removeTrack(id: id, fromPlaylist: playlistID), targetName: "Music")
        try Self.checkTimeout(out)
        try Self.checkRefused(out)
        return out == "ok"
    }

    public func deletePlaylist(id: String) async throws -> Bool {
        let out = try await AppleScript.run(MusicScripts.deletePlaylist(id: id), targetName: "Music")
        try Self.checkTimeout(out)
        try Self.checkRefused(out)
        return out == "ok"
    }

    public func rate(trackID: String, rating0to100: Int) async throws -> Bool {
        let out = try await AppleScript.run(MusicScripts.rate(trackID: trackID, rating0to100: rating0to100), targetName: "Music")
        try Self.checkTimeout(out)
        return out == "ok"
    }

    // MARK: - Parsing (static, unit-tested)

    /// The sanctioned `whose persistent ID is` lookups (MusicScripts) distinguish
    /// an AppleEvent timeout (-1712) from a genuine not-found by returning the
    /// "TIMEOUT" sentinel instead of "NOTFOUND". A timeout means "unknown", not
    /// "confirmed absent", so it must not collapse into the same false/nil result
    /// the rest of this store gives NOTFOUND — it's surfaced as a plain (internal
    /// envelope) error instead of a MacError, since it isn't the caller's fault.
    static func checkTimeout(_ output: String) throws {
        guard output == "TIMEOUT" else { return }
        throw NSError(domain: "Music", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Music id lookup timed out after 30s — library may be too large for direct id addressing."
        ])
    }

    /// Some playlists (Favorite Songs, measured live) misreport as
    /// class=user playlist / specialKind=none, so MusicActions' kind guard
    /// passes them through — and the mutation verb itself then refuses (e.g.
    /// "user playlist id ... doesn't understand the 'delete' message").
    /// MusicScripts wraps the verb (addTrack/removeTrack/deletePlaylist) in
    /// its own try and returns "REFUSED:<message>" instead of letting that
    /// raw AppleScript error surface via the internal envelope. This is the
    /// caller's mistake in the sense that the id resolved to something not
    /// actually mutable — badInput, not an internal error.
    static func checkRefused(_ output: String) throws {
        guard output.hasPrefix("REFUSED:") else { return }
        let message = String(output.dropFirst("REFUSED:".count))
        throw MacError(.badInput,
            "Music refused the operation: \(message). Some playlists (e.g. Favorites) are protected even though Music reports them as user playlists.")
    }

    /// Player record fields: state FS volume FS position FS trackID FS name FS
    /// artist FS album FS duration FS rating (9 fields with a track; the NOTRACK
    /// sentinel record — state FS volume FS "-1" FS "NOTRACK" — has 4).
    static func parsePlayerState(from output: String) -> PlayerState {
        let fields = output.components(separatedBy: AppleScript.fieldSep)
        let state = fields.count > 0 ? fields[0] : "stopped"
        let volume = fields.count > 1 ? (Int(fields[1]) ?? 0) : 0
        guard fields.count >= 9, fields[3] != "NOTRACK" else {
            return PlayerState(state: state, volume: volume, track: nil, positionSeconds: nil)
        }
        let position = Int(fields[2]).flatMap { $0 >= 0 ? $0 : nil }
        let track = TrackItem(id: fields[3], name: fields[4], artist: fields[5], album: fields[6],
                              durationSeconds: Int(fields[7]) ?? 0,
                              rating: starRating(from: fields[8]), playlist: nil)
        return PlayerState(state: state, volume: volume, track: track, positionSeconds: position)
    }

    /// Music's 0-100 rating -> 0-5 stars, rounding at the midpoint of each
    /// 20-point band (so 10, 30, 50, 70, 90 round UP into the next star).
    static func starRating(from field: String) -> Int {
        guard let raw = Int(field) else { return 0 }
        return (raw + 10) / 20
    }

    /// Track rows (search results): persistentID FS name FS artist FS album FS
    /// duration FS rating.
    static func parseTracks(from output: String) -> [TrackItem] {
        let records = AppleScript.parseRecords(output)
        var seen = Set<String>()
        var malformed = 0
        let items = records.compactMap { fields -> TrackItem? in
            guard fields.count >= 6, let duration = Int(fields[4]) else { malformed += 1; return nil }
            guard seen.insert(fields[0]).inserted else { return nil }
            return TrackItem(id: fields[0], name: fields[1], artist: fields[2], album: fields[3],
                             durationSeconds: duration, rating: starRating(from: fields[5]), playlist: nil)
        }
        warnIfDropped(malformed, noun: "track")
        return items
    }

    /// Playlist rows: persistent ID FS name FS (count of tracks) FS specialKindText
    /// FS classText. Kind mapping: class contains "user" AND special kind in
    /// ("none", "") -> "user", else "system".
    static func parsePlaylists(from output: String) -> [PlaylistInfo] {
        let records = AppleScript.parseRecords(output)
        var seen = Set<String>()
        var malformed = 0
        let infos = records.compactMap { fields -> PlaylistInfo? in
            guard fields.count >= 5, let count = Int(fields[2]) else { malformed += 1; return nil }
            guard seen.insert(fields[0]).inserted else { return nil }
            let kind = kind(classText: fields[4], specialKindText: fields[3])
            return PlaylistInfo(id: fields[0], name: fields[1], trackCount: count, kind: kind)
        }
        warnIfDropped(malformed, noun: "playlist")
        return infos
    }

    static func kind(classText: String, specialKindText: String) -> String {
        let isUserClass = classText.lowercased().contains("user")
        let specialKind = specialKindText.trimmingCharacters(in: .whitespaces)
        let isNoneSpecialKind = specialKind.isEmpty || specialKind.caseInsensitiveCompare("none") == .orderedSame
        return (isUserClass && isNoneSpecialKind) ? "user" : "system"
    }

    static func warnIfDropped(_ dropped: Int, noun: String) {
        if dropped > 0 {
            FileHandle.standardError.write(Data("warning: skipped \(dropped) unparseable \(noun) record(s)\n".utf8))
        }
    }
}
