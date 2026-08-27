# mac-cli v4 (Music, TV, Shortcuts, Call) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement task-by-task. Steps use checkbox syntax.

**Goal:** Ship `mac music` (full CRUD), `mac tv`, `mac shortcuts`, and `mac call`/`mac facetime`, with doctor coverage, docs, and smoke additions — version 0.4.0.

**Architecture:** Three AppleScript modules on the established store-protocol pattern plus one pure-Swift URL module. The repo itself is the canonical reference: mirror the REVIEWED sibling files named in each task for mechanical structure; this plan specifies everything behavior-defining (protocols, models, script shapes, mappings, validations) in full.

**Tech Stack:** Swift 5.9+, swift-argument-parser, NSAppleScript via Core.AppleScript, XCTest. macOS 14+.

**Conventions (all tasks — the accumulated law of this repo):**
- Escape EVERY interpolated user value with `AppleScript.escape`. Every script wrapped in `with timeout` (600s default; the sanctioned `whose persistent ID` lookups use 30s). Bulk fetches coerced `as list`. FS/RS records via `AppleScript.fieldSep/recordSep`; parse with `AppleScript.parseRecords`; dedupe by id at store parse; `warnIfDropped(_:noun:)`.
- **`whose` is banned EXCEPT the one sanctioned shape**: `first track of <container> whose persistent ID is "<escaped>"` (and the playlist equivalent) inside `with timeout of 30 seconds` — Music/TV only, per the spec's measured-exception section. A test must assert no OTHER `whose` appears in any generated script.
- TDD every task: tests first, observe red, implement, observe green. Fix implementations, not expectations; BLOCKED if an expectation is wrong. osacompile every builder variant (compile-only). NEVER run live music/tv/shortcuts/call commands — `--help`, `swift test`, `bash -n`, `mac doctor`, osacompile only. The coordinator does all live verification.
- Exit codes 0/1/2 (+64); --json always prints; mutations via `Output.emitConfirmation`; locked exact-string JSON schemas; ambiguity → badInput naming sorted capped-5 candidates; unknown ids → notFound naming the discovery command.
- Commit per task with the given message + trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` on its own line. Branch `v4` (create from main first). Baseline: 222 tests.

---

### Task 1: Core — media models with locked JSON schemas

**Files:** Create `Sources/Core/MediaModels.swift`; Test `Tests/CoreTests/MediaModelsTests.swift`.
Mirror the structure of `Sources/Core/NotesModels.swift` (memberwise public inits, `humanDate` NOT needed here — no Date fields).

Models (complete contract — implement exactly):

```swift
public struct TrackItem: Codable, Equatable, HumanRenderable {
    public let id: String          // Music persistent ID
    public let name: String
    public let artist: String
    public let album: String
    public let durationSeconds: Int
    public let rating: Int         // 0–5 stars (store maps from 0–100)
    public let playlist: String?   // context, omitted when n/a
    public var humanLine: String { "\(id)  \(name)  \(artist)  \(album)" }
}
public struct PlaylistInfo: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let trackCount: Int
    public let kind: String        // "user" | "system"
    public var humanLine: String { "\(id)  \(name)  \(trackCount) tracks  [\(kind)]" }
}
public struct PlayerState: Codable, Equatable, HumanRenderable {
    public let state: String       // "playing" | "paused" | "stopped"
    public let volume: Int
    public let track: TrackItem?   // omitted when stopped/no track
    public let positionSeconds: Int?
    public var humanLine: String {
        let t = track.map { "  \($0.name) — \($0.artist)" } ?? ""
        return "\(state)  vol \(volume)\(t)"
    }
}
public struct TVItem: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let kind: String        // "movie" | "episode" | "other"
    public let show: String?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public var humanLine: String {
        let ctx = show.map { "  [\($0)]" } ?? ""
        return "\(id)  \(name)\(ctx)  (\(kind))"
    }
}
public struct ShortcutInfo: Codable, Equatable, HumanRenderable {
    public let id: String
    public let name: String
    public let folder: String?
    public var humanLine: String { folder.map { "\(id)  \(name)  [\($0)]" } ?? "\(id)  \(name)" }
}
```

Tests: exact-string schema assertions for each model (sorted keys; verify optional omission for playlist/track/show/folder/positionSeconds), plus humanLine checks. ~6 tests. Commit: `feat: add media, shortcut, and player models`. Expected suite: ~228.

### Task 2: MusicModule — protocol, actions, mock tests

**Files:** Create `Sources/MusicModule/MusicStore.swift`, `MusicActions.swift`, `MusicModule.swift` placeholder; modify `Package.swift` (target + test target + MacCLI dep, mirroring NotesModule entries); Test `Tests/MusicModuleTests/MusicActionsTests.swift`. Mirror `Sources/NotesModule/NoteActions.swift` structure.

Protocol (exact):

```swift
public protocol MusicStore {
    func playerState() async throws -> PlayerState
    func resume() async throws
    func pause() async throws
    func next() async throws
    func previous() async throws
    func setVolume(_ volume: Int) async throws
    func playPlaylist(id: String) async throws -> Bool
    func playTrack(id: String) async throws -> Bool
    func search(_ query: String, limit: Int) async throws -> [TrackItem]
    func playlists() async throws -> [PlaylistInfo]
    func createPlaylist(name: String) async throws -> PlaylistInfo
    func addTrack(id: String, toPlaylist playlistID: String) async throws -> Bool
    func removeTrack(id: String, fromPlaylist playlistID: String) async throws -> Bool
    func deletePlaylist(id: String) async throws -> Bool
    func rate(trackID: String, rating0to100: Int) async throws -> Bool
}
```

MusicActions behavior contract (implement fully; validation before store calls):
- `now()` → playerState passthrough.
- `play(playlist: String?, trackID: String?)`: both nil → resume; both set → badInput "Pass --playlist or --track-id, not both."; playlist name resolved via `playlists()` case-insensitively with ambiguity rejection (candidates = ids, message lists `name (id)` pairs, capped 5, hint: use the id from `mac music playlists` — resolution also accepts an exact id match first); unknown → notFound "Run: mac music playlists". trackID → playTrack, false → notFound "Run: mac music search".
- `pause/next/previous` passthrough. `volume(nil)` → playerState().volume (get); `volume(n)` validate 0...100 → set, echo n.
- `search(query:limit:)`: trim/reject empty; limit 1...200.
- `playlistCreate(name:)`: trim/reject empty; also reject if an existing playlist already has that exact name (case-insensitive) → badInput "already exists".
- `playlistAdd/Remove(playlist:trackID:)` and `playlistDelete(name:)`: resolve name/id as in play, then **kind guard**: resolved playlist must be kind "user", else badInput "'<name>' is a system playlist — only user playlists can be modified."; then store call, false → notFound (track or playlist vanished).
- `rate(trackID:stars:)`: stars 0...5 else badInput; store gets stars*20; false → notFound.

MockMusicStore: fidelity mock — playlists list with mixed kinds, tracks map, records mutations, honors Bool-false-on-unknown. ~16 tests covering: both-flags badInput; playlist ambiguity (two "Chill" playlists) message contains both ids; exact-id resolution bypasses ambiguity; unknown playlist notFound; system-playlist mutation guard (add/remove/delete each); duplicate create badInput; volume get vs set + range; rating range + ×20 mapping asserted via mock capture; search validation; unknown track notFound; permissionDenied propagation. Commit: `feat: add MusicStore protocol and mock-tested MusicActions`. Expected: ~244.

### Task 3: MusicModule — AppleScript builders

**Files:** Create `Sources/MusicModule/MusicScripts.swift`; Test `Tests/MusicModuleTests/MusicScriptsTests.swift`. Mirror `Sources/NotesModule/NoteScripts.swift` conventions (prologue FS/RS only — no date handlers needed).

Behavior-defining script shapes (implement these semantics):
- `playerState()`: emit ONE record `state FS volume FS position FS trackID FS name FS artist FS album FS duration FS rating` where state = (`player state as text`), position via try (error → "-1"), track fields via `try current track` (no track → sentinel record `state FS volume FS -1 FS NOTRACK`).
- `resume()` = `playpause`-free explicit `play`; `pause()`; `next()` = `next track`; `previous()` = `previous track`; `setVolume` = `set sound volume to N`. All return "ok".
- `search(query:limit:)`: `set results to search library playlist 1 for "<escaped>"` then bounded loop `repeat with i from 1 to n` (n = min(limit, count of results)) emitting track records `persistentID FS name FS artist FS album FS duration FS rating` — fetch properties per item (results are already bounded by n; per-item props on ≤200 items is the accepted cost).
- `playlists()`: loop `repeat with p in playlists` emitting `persistent ID FS name FS (count of tracks) FS specialKindText FS classText` (class/special kind via `as text` in try, default ""). Store maps kind: class contains "user" AND special kind in ("none","␀") → "user" else "system".
- By-id fragments (the sanctioned exception, exact shape):
```applescript
with timeout of 30 seconds
    set theTrack to (first track of library playlist 1 whose persistent ID is "<escaped>")
end timeout
```
wrapped in try → sentinel `NOTFOUND`. Same for `first playlist whose persistent ID is`.
- `playTrack(id)`: locate then `play theTrack`. `playPlaylist(id)`: locate then `play thePlaylist`.
- `createPlaylist(name)`: `make new user playlist with properties {name:"<escaped>"}` then emit its playlist record.
- `addTrack(id:toPlaylist:)`: locate both → `duplicate theTrack to thePlaylist` → "ok". `removeTrack`: locate playlist → `first track of thePlaylist whose persistent ID is` (sanctioned shape, 30s) → `delete theTrack` → "ok"/NOTFOUND. `deletePlaylist(id)`: locate → `delete thePlaylist` → "ok".
- `rate(trackID:rating0to100:)`: locate → `set rating of theTrack to N` → "ok".

Tests (~8): every variant contains `with timeout`; the ONLY `whose` occurrences match the sanctioned `whose persistent ID is` shape (regex/count assertion); escaping of query/name/id incl. quotes; search contains `search library playlist 1 for`; sentinel presence; rating script contains the raw 0–100 value; playlists loop has no `whose`. Then **osacompile ALL variants** (report N/N). Commit: `feat: add Music AppleScript builders`. Expected: ~252.

### Task 4: MusicModule — store, command, wiring

**Files:** Create `Sources/MusicModule/AppleScriptMusicStore.swift`, `MusicCommand.swift`; modify `Sources/MacCLI/Mac.swift` (import + register before DoctorCommand + abstract mention); Test `Tests/MusicModuleTests/AppleScriptMusicStoreTests.swift` (parsing: player record with/without track, rating /20 round-half mapping 0–100→0–5 via `(r + 10) / 20`, track/playlist row parsing + dedupe + malformed warn), `Tests/MusicModuleTests/MusicCommandParsingTests.swift` (~4 parse-only). Mirror `AppleScriptNoteStore.swift` + `NotesCommand.swift`.

Command surface (subcommands): `Now, Play(--playlist/--track-id), Pause, Next, Prev, Volume([level] optional positional Int), Search(query, --limit 20), Playlists, PlaylistCreate("playlist-create", name), PlaylistAdd("playlist-add", playlist, trackID), PlaylistRemove("playlist-remove", ...), PlaylistDelete("playlist-delete", name), Rate(trackID, stars Int)`. Reads emit items/state; mutations emitConfirmation (keys: "playing", "paused", "skipped", "volume", "created" — created emits the PlaylistInfo item instead, json||!quiet — "added", "removed", "deleted", "rated"). Help discussions include examples; Play's discussion documents resume-when-no-flags. `swift run mac music --help` verified. Commit: `feat: add AppleScript music store and mac music subcommands`. Expected: ~262.

### Task 5: TVModule — protocol, actions, mocks

**Files:** `Sources/TVModule/{TVStore,TVActions,TVModule}.swift`; Package.swift entries; `Tests/TVModuleTests/TVActionsTests.swift`. Protocol:

```swift
public protocol TVStore {
    func playerState() async throws -> PlayerState   // track fields reused; artist=show or "", album=""
    func pause() async throws
    func resume() async throws
    func list(limit: Int) async throws -> [TVItem]
    func play(id: String) async throws -> Bool
}
```

TVActions: now/pause/resume passthrough; list validates limit 1...500; play(id) false → notFound "Run: mac tv list". ~5 tests incl. permissionDenied. Commit: `feat: add TVStore protocol and mock-tested TVActions`. Expected: ~267.

### Task 6: TVModule — scripts, store, command, wiring

**Files:** `Sources/TVModule/{TVScripts,AppleScriptTVStore,TVCommand}.swift`; Mac.swift wiring; `Tests/TVModuleTests/{TVScriptsTests,TVCommandParsingTests}.swift`. Script shapes: playerState mirrors Music's (artist field ← `try show of current track` else ""); `list`: bulk over `tracks of library playlist 1` — ids/names as list, then per-item try for `video kind as text`, `show`, `season number`, `episode number` bounded by `min(limit, count)` loop (per-item props acceptable; library is store-managed and small relative to Mail); kind mapping in Swift: contains "movie"→movie, contains "TV"/"episode"→episode, else other. `play(id)` sanctioned whose-by-id + `play`. Tests: timeout/whose-shape/escaping/sentinels + parse tests; osacompile all. Command: `Now, Pause, Resume, List(--limit 50), Play(id)`. Commit: `feat: add TV module with playback and library listing`. Expected: ~276.

### Task 7: ShortcutsModule — complete

**Files:** `Sources/ShortcutsModule/{ShortcutStore,ShortcutActions,ShortcutScripts,AppleScriptShortcutStore,ShortcutsCommand,ShortcutsModule}.swift`; Package.swift; tests (actions ~5, scripts ~3, parsing ~2). Protocol:

```swift
public protocol ShortcutStore {
    func list() async throws -> [ShortcutInfo]
    /// Runs by exact id. Returns the shortcut's textual output ("" when none).
    func run(id: String, input: String?) async throws -> String
}
```

Actions: `list()` sorted by name (localizedCaseInsensitive). `run(nameOrID:input:isID:)`: if isID → direct; else resolve against list() by exact case-insensitive name — 0 → notFound "Run: mac shortcuts list"; >1 → badInput listing `name (id)` candidates + "--id" hint. Scripts target `tell application "Shortcuts Events"` (NOT "Shortcuts" — Events avoids opening the app): list emits `id FS name FS folderName` (folder via per-item try → ""); run: `set r to run shortcut id "<escaped>"` (+ ` with input "<escaped>"` when provided) in try → `on error m` → return `"SHORTCUTERR:" & m`; success returns `r as text` in try else "ok". Store maps SHORTCUTERR → badInput carrying the message. Command: `List`, `Run(nameOrID, --input, --id flag)` — run's output printed raw in human mode, `{"output":"..."}` via emitConfirmation-style JSON (use Output JSON-safe serialization, NOT interpolation). Doctor row NOT here (Task 9). osacompile. Commit: `feat: add Shortcuts module (list/run via Shortcuts Events)`. Expected: ~286.

### Task 8: CallModule — pure Swift

**Files:** `Sources/CallModule/{CallURLBuilder,CallCommands,CallModule}.swift`; Package.swift (deps: Core only); `Tests/CallModuleTests/CallURLBuilderTests.swift` (~6) + parse tests (~2); Mac.swift registers BOTH `CallCommand` (name "call") and `FaceTimeCommand` (name "facetime"). Builder (exact contract):

```swift
public enum CallURLBuilder {
    /// Accepts digits, +, and separators ( ) - . and spaces; strips separators.
    /// Result must be + followed by 7–15 digits, or 3–15 bare digits — else badInput.
    public static func telURL(number: String) throws -> URL
    /// Trims; requires non-empty; @ or digits-only handles both allowed;
    /// percent-encodes with .urlHostAllowed; scheme facetime:// or facetime-audio://.
    public static func facetimeURL(handle: String, audio: Bool) throws -> URL
}
```

Commands: argument handle/number; `--dry-run` flag prints the URL WITHOUT opening (human: `would open <url>`; json: `{"url":"..."}` via JSONSerialization); real path routes through `static var opener: (URL) throws -> Void` (default: `NSWorkspace.shared.open` — but implement as `Process` running `/usr/bin/open <url>` for CLI reliability; your choice, comment why) then emits `{"opening":"<url>"}` / `opening <url>`. Tests: exact URLs (`tel:+15551234567` from `"+1 (555) 123-4567"`, facetime vs facetime-audio, encoding of `user@example.com`), rejection cases, and opener-injection tests proving dry-run never calls it. Commit: `feat: add call and facetime URL commands`. Expected: ~294.

### Task 9: Doctor, docs, smoke, version

**Files:** modify `Sources/MacCLI/DoctorCommand.swift` (+3 rows: `automation:Music` com.apple.Music hint "music"; `automation:TV` com.apple.TV hint "tv"; `automation:Shortcuts` com.apple.shortcuts.events hint "shortcuts run", app label "Shortcuts Events"), `Sources/MacCLI/Mac.swift` (version 0.4.0), `README.md`, `scripts/smoke.sh`.

README: intro sentence gains Music/TV/Shortcuts; Usage gains music/tv/shortcuts/call examples; For agents gains "call/facetime are initiate-only; macOS confirms before dialing" + "shortcuts run is the escape hatch for unscriptable apps"; Known limitations gains music-library-not-catalog, the whose-by-id measured exception note, shortcuts-run-blocks, call-initiate-only; NEW section `## Scriptability of other Apple apps` with the surveyed table (scriptable-future: Photos, QuickTime, Preview, TextEdit, Keynote/Pages/Numbers, Finder; no-API: Podcasts, News, Stocks, FaceTime/Phone beyond dialing, Maps, Weather, Books, Voice Memos, Freeform, Journal, Home, Passwords — workaround: wrap in a Shortcut, run with `mac shortcuts run`); Roadmap: "Finder (v5), iWork — Keynote/Pages/Numbers (v6), Homebrew tap."

smoke.sh additions before PASS (etiquette per spec — no playback hijack, no dialing):
```bash
echo "== music =="
"$MAC" music now >/dev/null
"$MAC" music playlists >/dev/null
TRACK_ID=$("$MAC" music search "a" --limit 1 --json | json_field 0 2>/dev/null || true)
PL_ID=$("$MAC" music playlist-create "mac-cli smoke playlist" --json | json_field id)
"$MAC" music playlist-delete "mac-cli smoke playlist" --quiet
echo "== tv =="
"$MAC" tv list --limit 3 >/dev/null
echo "== shortcuts =="
"$MAC" shortcuts list >/dev/null
echo "== call (dry-run only — never dials) =="
"$MAC" call "+15551234567" --dry-run | grep -q "tel:+15551234567"
"$MAC" facetime "smoke@example.com" --dry-run --audio | grep -q "facetime-audio://"
```
(Adjust the search line: `json_field 0` is wrong for an array — use python to take `[0]["id"]`; write it correctly with the existing json_field helper style, tolerating an empty library by skipping the add/remove pair when no track found. Keep playlist create/delete unconditional.)

Verify: build, full test count (report), `bash -n`, `mac --version` 0.4.0, `mac doctor` 10 rows (safe). Commit: `docs: document v4 modules, scriptability survey, and smoke coverage`. Expected: ~294 tests.

---

## Done criteria

Build+tests green; nine command trees + doctor(10 rows); no unsanctioned `whose` (test-enforced); all builders osacompile-clean; README table accurate; coordinator live pass covers: music now/search/playlists/playlist-CRUD/rate round-trip on a real track (restored after), polite pause/resume, the whose-by-id timing measurement, tv list/now, shortcuts list + run of a harmless shortcut if present, call --dry-run only. Merge → install → push → memory.
