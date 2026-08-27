import Core
import Foundation

/// Pure AppleScript source builders for TV.app. Mirrors MusicScripts'
/// conventions: every user value passes through AppleScript.escape; every
/// script bounded by a timeout; bulk fetches coerced `as list`. `whose` is
/// banned EXCEPT the one sanctioned shape — `first track of <container>
/// whose persistent ID is "<id>"` — wrapped in `with timeout of 30 seconds`
/// and a surrounding `try` that returns the NOTFOUND sentinel on failure.
///
/// NOTE: `st` is a RESERVED word in TV.app's (and Music.app's) AppleScript
/// terminology (it collides with the app's own "st" enum abbreviation) —
/// every local that would naturally be named `st` is spelled `stateText`
/// (or similar) instead, per the Music module's discovery of this gotcha.
///
/// TV.app has its own reserved word not shared with Music: `names` is a
/// search-scope enumerator (`kSrS`, "track names only"). `set names to ...`
/// inside `tell application "TV"` resolves to that constant instead of
/// declaring a local, and fails to compile ("Can't set «constant ...»").
/// Caught by osacompile — the local is spelled `theNames` instead.
enum TVScripts {
    static let prologue = """
    set FS to character id 31
    set RS to character id 30
    """

    /// The sanctioned `whose persistent ID is` lookup, wrapped in its own
    /// 30s timeout and a `try` that returns the NOTFOUND sentinel. -1712 is
    /// AppleEvent's "event timed out" error number — distinct from every
    /// other failure (element genuinely absent, app not running, etc.),
    /// which all collapse to NOTFOUND. The store maps TIMEOUT to a thrown
    /// error instead of a false/nil result, since it means "unknown", not
    /// "confirmed absent".
    private static func locateTrackInLibrary(id: String, varName: String = "theTrack") -> String {
        """
        try
                    with timeout of 30 seconds
                        set \(varName) to (first track of library playlist 1 whose persistent ID is "\(AppleScript.escape(id))")
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

    // MARK: - Player state

    /// Same 9-field shape as Music's playerState (state FS volume FS position
    /// FS trackID FS name FS artist FS album FS duration FS rating), but TV
    /// tracks carry a show, not an artist/album: artist <- `try show of
    /// current track` else "", album is always "". No-track case falls back
    /// to the same 4-field NOTRACK sentinel record as Music.
    static func playerState() -> String {
        """
        \(prologue)
        tell application "TV"
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
                    set tartist to ""
                    try
                        set tartist to (show of curTrack) as text
                    end try
                    set talbum to ""
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
        tell application "TV"
            with timeout of 600 seconds
                play
            end timeout
        end tell
        return "ok"
        """
    }

    static func pause() -> String {
        """
        tell application "TV"
            with timeout of 600 seconds
                pause
            end timeout
        end tell
        return "ok"
        """
    }

    // MARK: - Library

    /// Bulk-fetches ids/names `as list` over `tracks 1 thru k of library
    /// playlist 1` (k = min(limit, count)), then per-item `try` for `media
    /// kind as text` (TV.app's terminology for what Music.app calls "video
    /// kind" — confirmed via `sdef /System/Applications/TV.app`; the enum
    /// values are "home video"/"movie"/"TV show"/"unknown", which the store's
    /// kind-mapping substring match expects), `show`, `season number`,
    /// `episode number` — per-item property fetches on a bounded slice are
    /// the accepted cost here, same as Music's search/playlists (the library
    /// is store-managed and small relative to Mail's mailboxes). Guarded so
    /// k = 0 (empty library) never attempts `tracks 1 thru 0`, which
    /// AppleScript rejects as an invalid range.
    ///
    /// Live bug (measured on a library with exactly one `shared track`):
    /// `tracks 1 thru k of library playlist 1` with k=1 resolves to a BARE
    /// track reference rather than a list, so indexing it with `item i of`
    /// fails ("Can't get item 1 of shared track id ..."). `as list` reliably
    /// coerces PROPERTY VALUES (text/numbers) even when there's only one —
    /// that's why `ids`/`theNames` below are safe — but it does not coerce
    /// an OBJECT-SPECIFIER range into an indexable list. So the per-item
    /// object reference is fetched by re-indexing the container directly
    /// each iteration (`track i of library playlist 1`) instead of holding
    /// an object-range variable and indexing into it. Fourth reserved/
    /// surprising-behavior discovery in this app family, after `st`,
    /// `names`, and the Notes module's flattened-folder walk: object ranges
    /// don't coerce to lists the way property-value ranges do.
    static func list(limit: Int) -> String {
        """
        \(prologue)
        set out to {}
        tell application "TV"
            with timeout of 600 seconds
                set k to (count of tracks of library playlist 1)
                if k > \(limit) then set k to \(limit)
                if k > 0 then
                    set ids to ((persistent ID of tracks 1 thru k of library playlist 1) as list)
                    set theNames to ((name of tracks 1 thru k of library playlist 1) as list)
                    repeat with i from 1 to k
                        set t to track i of library playlist 1
                        set kindText to ""
                        try
                            set kindText to (media kind of t) as text
                        end try
                        set showText to ""
                        try
                            set showText to (show of t) as text
                        end try
                        set seasonText to ""
                        try
                            set seasonText to (season number of t) as text
                        end try
                        set episodeText to ""
                        try
                            set episodeText to (episode number of t) as text
                        end try
                        set rec to ((item i of ids) as text) & FS & (item i of theNames) & FS & kindText & FS & showText & FS & seasonText & FS & episodeText
                        copy rec to end of out
                    end repeat
                end if
            end timeout
        end tell
        set AppleScript's text item delimiters to RS
        return out as text
        """
    }

    // MARK: - Playback

    static func play(id: String) -> String {
        """
        tell application "TV"
            with timeout of 600 seconds
                \(locateTrackInLibrary(id: id))
                play theTrack
            end timeout
        end tell
        return "ok"
        """
    }
}
