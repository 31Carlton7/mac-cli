import Core
import Foundation

/// Pure AppleScript source builders for Music.app. Every user value passes
/// through AppleScript.escape; every script bounded by a timeout; bulk
/// fetches coerced `as list`. `whose` is banned EXCEPT the one sanctioned
/// shape — `first track of <container> whose persistent ID is "<id>"` (and
/// the playlist equivalent) — wrapped in `with timeout of 30 seconds` and a
/// surrounding `try` that returns the NOTFOUND sentinel on failure. That
/// shape is the only place a persistent-ID lookup by identity is safe to do
/// with `whose`; everywhere else we loop and match in Swift/parse layer
/// instead, per the Mail v2 "whose wedges large stores" lesson.
enum MusicScripts {
    // No date handlers needed (no dates in Music records), so the prologue
    // is just the field/record separators — unlike NotesModule's prologue,
    // there's no top-level `on ... end` handler to keep `with timeout`
    // nested inside `tell` for; we nest it anyway for consistency with the
    // rest of the repo's builders.
    static let prologue = """
    set FS to character id 31
    set RS to character id 30
    """

    /// The sanctioned `whose persistent ID is` lookup, wrapped in its own
    /// 30s timeout and a `try` that returns the NOTFOUND sentinel. `container`
    /// is the AppleScript expression to search within (e.g. `library playlist 1`
    /// for tracks, or omitted for `first playlist`). Sets `varName` in scope.
    /// -1712 is AppleEvent's "event timed out" error number — distinct from
    /// every other failure (element genuinely absent, app not running, etc.),
    /// which all collapse to NOTFOUND. The store maps TIMEOUT to a thrown
    /// error instead of a false/nil result, since it means "unknown", not
    /// "confirmed absent".
    private static func locateByPersistentID(
        kind: String, container: String?, id: String, varName: String
    ) -> String {
        let containerExpr = container.map { "\($0) " } ?? ""
        return """
        try
                    with timeout of 30 seconds
                        set \(varName) to (first \(kind) of \(containerExpr)whose persistent ID is "\(AppleScript.escape(id))")
                    end timeout
                on error number errNum
                    if errNum is -1712 then
                        return "TIMEOUT"
                    else
                        return "NOTFOUND"
                    end if
                end try
        """
    }

    private static func locateTrackInLibrary(id: String, varName: String = "theTrack") -> String {
        locateByPersistentID(kind: "track", container: "library playlist 1", id: id, varName: varName)
    }

    private static func locateTrackInPlaylist(id: String, playlistVar: String, varName: String = "theTrack") -> String {
        locateByPersistentID(kind: "track", container: playlistVar, id: id, varName: varName)
    }

    /// No container: `first playlist whose persistent ID is "..."` — the plan's
    /// exact "playlist equivalent" of the track shape.
    ///
    /// Kind-guarding (a resolved playlist must be "user", not "system", before
    /// it's mutated) is the actions layer's job — see
    /// `MusicActions.requireUserPlaylist`. This helper resolves by identity
    /// only; it does not and must not check kind. Any direct caller of a
    /// script built on this helper (i.e. anything other than going through
    /// MusicActions) is responsible for applying that guard itself before
    /// mutating the result.
    private static func locatePlaylist(id: String, varName: String = "thePlaylist") -> String {
        """
        try
                    with timeout of 30 seconds
                        set \(varName) to (first playlist whose persistent ID is "\(AppleScript.escape(id))")
                    end timeout
                on error number errNum
                    if errNum is -1712 then
                        return "TIMEOUT"
                    else
                        return "NOTFOUND"
                    end if
                end try
        """
    }

    /// One playlist's record fields, given a variable already bound to it.
    /// specialKind/class are emitted as raw `as text` for the store to map
    /// into "user"/"system" — see MusicActions/AppleScriptMusicStore.
    private static func playlistRecord(varName: String, into recVar: String) -> String {
        """
        set pid to (persistent ID of \(varName)) as text
                set pname to name of \(varName)
                set tcount to (count of tracks of \(varName)) as text
                set skText to ""
                try
                    set skText to (special kind of \(varName)) as text
                end try
                set clsText to ""
                try
                    set clsText to (class of \(varName)) as text
                end try
                set \(recVar) to pid & FS & pname & FS & tcount & FS & skText & FS & clsText
        """
    }

    // MARK: - Player state

    static func playerState() -> String {
        """
        \(prologue)
        tell application "Music"
            with timeout of 600 seconds
                set stateText to (player state as text)
                set vol to (sound volume) as text
                try
                    set curTrack to current track
                    set pos to "-1"
                    try
                        set pos to (player position as integer) as text
                    end try
                    set tid to (persistent ID of curTrack) as text
                    set tname to name of curTrack
                    set tartist to artist of curTrack
                    set talbum to album of curTrack
                    set tdur to (duration of curTrack) as integer as text
                    set trating to (rating of curTrack) as text
                    set rec to stateText & FS & vol & FS & pos & FS & tid & FS & tname & FS & tartist & FS & talbum & FS & tdur & FS & trating
                on error
                    set rec to stateText & FS & vol & FS & "-1" & FS & "NOTRACK"
                end try
            end timeout
        end tell
        return rec
        """
    }

    // MARK: - Transport

    static func resume() -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                play
            end timeout
        end tell
        return "ok"
        """
    }

    static func pause() -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                pause
            end timeout
        end tell
        return "ok"
        """
    }

    static func next() -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                next track
            end timeout
        end tell
        return "ok"
        """
    }

    static func previous() -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                previous track
            end timeout
        end tell
        return "ok"
        """
    }

    static func setVolume(_ volume: Int) -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                set sound volume to \(volume)
            end timeout
        end tell
        return "ok"
        """
    }

    // MARK: - Search

    static func search(query: String, limit: Int) -> String {
        """
        \(prologue)
        set out to {}
        tell application "Music"
            with timeout of 600 seconds
                set results to (search library playlist 1 for "\(AppleScript.escape(query))") as list
                set n to (count of results)
                if n > \(limit) then set n to \(limit)
                repeat with i from 1 to n
                    set t to item i of results
                    set rec to ((persistent ID of t) as text) & FS & (name of t) & FS & (artist of t) & FS & (album of t) & FS & ((duration of t) as integer as text) & FS & ((rating of t) as text)
                    copy rec to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    // MARK: - Playlists

    static func playlists() -> String {
        """
        \(prologue)
        set out to {}
        tell application "Music"
            with timeout of 600 seconds
                repeat with p in playlists
                    \(playlistRecord(varName: "p", into: "rec"))
                    copy rec to end of out
                end repeat
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    static func createPlaylist(name: String) -> String {
        """
        \(prologue)
        tell application "Music"
            with timeout of 600 seconds
                set p to make new user playlist with properties {name:"\(AppleScript.escape(name))"}
                \(playlistRecord(varName: "p", into: "rec"))
            end timeout
        end tell
        return rec
        """
    }

    static func deletePlaylist(id: String) -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                \(locatePlaylist(id: id))
                delete thePlaylist
            end timeout
        end tell
        return "ok"
        """
    }

    // MARK: - Track playback / membership

    static func playTrack(id: String) -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                \(locateTrackInLibrary(id: id))
                play theTrack
            end timeout
        end tell
        return "ok"
        """
    }

    static func playPlaylist(id: String) -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                \(locatePlaylist(id: id))
                play thePlaylist
            end timeout
        end tell
        return "ok"
        """
    }

    static func addTrack(id: String, toPlaylist playlistID: String) -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                \(locateTrackInLibrary(id: id))
                \(locatePlaylist(id: playlistID))
                duplicate theTrack to thePlaylist
            end timeout
        end tell
        return "ok"
        """
    }

    static func removeTrack(id: String, fromPlaylist playlistID: String) -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                \(locatePlaylist(id: playlistID))
                \(locateTrackInPlaylist(id: id, playlistVar: "thePlaylist"))
                delete theTrack
            end timeout
        end tell
        return "ok"
        """
    }

    // MARK: - Rating

    static func rate(trackID: String, rating0to100: Int) -> String {
        """
        tell application "Music"
            with timeout of 600 seconds
                \(locateTrackInLibrary(id: trackID))
                set rating of theTrack to \(rating0to100)
            end timeout
        end tell
        return "ok"
        """
    }
}
