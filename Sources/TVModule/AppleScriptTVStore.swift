import Core
import Foundation

public final class AppleScriptTVStore: TVStore {
    public init() {}

    public func playerState() async throws -> PlayerState {
        let out = try await AppleScript.run(TVScripts.playerState(), targetName: "TV")
        return Self.parsePlayerState(from: out)
    }

    public func pause() async throws {
        _ = try await AppleScript.run(TVScripts.pause(), targetName: "TV")
    }

    public func resume() async throws {
        _ = try await AppleScript.run(TVScripts.resume(), targetName: "TV")
    }

    public func list(limit: Int) async throws -> [TVItem] {
        let out = try await AppleScript.run(TVScripts.list(limit: limit), targetName: "TV")
        return Self.parseItems(from: out)
    }

    public func play(id: String) async throws -> Bool {
        let out = try await AppleScript.run(TVScripts.play(id: id), targetName: "TV")
        try Self.checkTimeout(out)
        return out == "ok"
    }

    // MARK: - Parsing (static, unit-tested)

    /// The sanctioned `whose persistent ID is` lookup (TVScripts.play) distinguishes
    /// an AppleEvent timeout (-1712) from a genuine not-found by returning the
    /// "TIMEOUT" sentinel instead of "NOTFOUND". A timeout means "unknown", not
    /// "confirmed absent", so it must not collapse into the same false/nil result
    /// the rest of this store gives NOTFOUND — it's surfaced as a plain (internal
    /// envelope) error instead of a MacError, since it isn't the caller's fault.
    static func checkTimeout(_ output: String) throws {
        guard output == "TIMEOUT" else { return }
        throw NSError(domain: "TV", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "TV id lookup timed out after 30s — library may be too large for direct id addressing."
        ])
    }

    /// Same 9-field shape as Music's player record (state FS volume FS position
    /// FS trackID FS name FS artist FS album FS duration FS rating), but the
    /// artist field carries the episode's show (or "" for a movie/no show) and
    /// album is always "" — TV tracks have no album. The NOTRACK sentinel
    /// record (4 fields) is identical to Music's.
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

    /// Same 0-100 -> 0-5 star mapping as Music: (r + 10) / 20, rounding at
    /// the midpoint of each 20-point band.
    static func starRating(from field: String) -> Int {
        guard let raw = Int(field) else { return 0 }
        return (raw + 10) / 20
    }

    /// Library rows: id FS name FS videoKindText FS showText FS seasonText FS
    /// episodeText. Kind mapping (case-insensitive substring match): contains
    /// "movie" -> "movie"; contains "tv" or "episode" -> "episode"; else
    /// "other". Season/episode "-1" or "" -> nil (not a season/episode, e.g.
    /// a movie or home video).
    static func parseItems(from output: String) -> [TVItem] {
        let records = AppleScript.parseRecords(output)
        var seen = Set<String>()
        var malformed = 0
        let items = records.compactMap { fields -> TVItem? in
            guard fields.count >= 6 else { malformed += 1; return nil }
            guard seen.insert(fields[0]).inserted else { return nil }
            let show = fields[3].isEmpty ? nil : fields[3]
            return TVItem(id: fields[0], name: fields[1], kind: kind(from: fields[2]), show: show,
                          seasonNumber: numberOrNil(fields[4]), episodeNumber: numberOrNil(fields[5]))
        }
        warnIfDropped(malformed, noun: "item")
        return items
    }

    static func kind(from videoKindText: String) -> String {
        let lowered = videoKindText.lowercased()
        if lowered.contains("movie") { return "movie" }
        if lowered.contains("tv") || lowered.contains("episode") { return "episode" }
        return "other"
    }

    static func numberOrNil(_ field: String) -> Int? {
        guard field != "-1", !field.isEmpty, let n = Int(field) else { return nil }
        return n
    }

    static func warnIfDropped(_ dropped: Int, noun: String) {
        if dropped > 0 {
            FileHandle.standardError.write(Data("warning: skipped \(dropped) unparseable \(noun) record(s)\n".utf8))
        }
    }
}
