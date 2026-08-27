# mac-cli v4 Design — Media (Music, TV) + Shortcuts + Call

**Date:** 2026-08-27
**Status:** Approved (user pre-approved single-pass build)
**Builds on:** v1–v3 (Calendar/Reminders/Contacts, Mail/Messages, Notes — all shipped)

## Purpose

Four modules in one release, unified by a theme: control what plays, and reach everything else.

- **`mac music`** — full CRUD over Music.app (31-command dictionary, the inherited iTunes surface): playback, now-playing, volume, library search, playlists (create/add/remove/delete), track rating.
- **`mac tv`** — TV.app (29 commands): now-playing, pause/resume, library listing, play by exact id.
- **`mac shortcuts`** — the universal escape hatch: list and run user Shortcuts via Shortcuts Events. One module that reaches every capability users wrap in a Shortcut — including apps with no scripting surface.
- **`mac call` / `mac facetime`** — initiate phone/FaceTime calls via the `tel:`/`facetime://`/`facetime-audio://` URL schemes. Initiate-only: macOS shows its own confirmation before dialing; there is no answer/hangup/state surface, and we don't pretend otherwise.

## Evidence base (surveyed live on Carlton's machine)

`sdef` survey of every native app: Music 31 cmds/26 classes; TV 29/16; Keynote 28/22 (v6, with Pages 11/23 and Numbers 16/21); Finder 25/32 (v5); Photos 18/6, QuickTime 14/5, Preview 13/12, TextEdit 13/12 (future candidates). **Zero scripting surface** (error -192): Podcasts, News, Stocks, FaceTime, Phone, Maps, Weather, Books, Voice Memos, Freeform, Journal, Stickies, Calculator, Home, Find My, Passwords. These CANNOT be modules; the README gains a scriptability table saying so, and Shortcuts is the documented workaround.

## Scope decisions

- Music is full CRUD (option c): playlist create/add/remove/delete and 0–5 star rating, plus playback/search. TV is read+playback only (its library is store-managed; no sensible CRUD).
- Shortcuts: `list` and `run <name> [--input text] [--id]`; duplicate names rejected with candidates (established ambiguity pattern), `--id` as the exact-address escape.
- Call: two root commands, `mac call <number>` and `mac facetime <handle> [--audio]`. No contact-name resolution (agents use `mac contacts find` — established rule). The OS dial-confirmation dialog is the safety gate; the CLI never bypasses it.
- **Smoke-test etiquette:** music/tv smoke must not hijack the user's listening — read paths plus a self-contained playlist round-trip (create smoke playlist → add one track → remove → delete). Playback mutation verification (pause/resume) happens in the coordinator's live pass, politely. `call`/`facetime` are NEVER dialed in tests — URL construction is unit-tested; the smoke prints the would-open URL via a --dry-run flag.

## The `whose persistent ID` exception (measured, bounded, with contingency)

The blanket no-`whose` ban (from Mail wedging at 97k messages) gets ONE narrow, justified exception: Music/TV id-addressing (`first track of playlist 1 whose persistent ID is "X"`). Rationale: the dictionaries provide no other id lookup; Music/TV are local databases (not Mail's remote-backed store); the clause is wrapped in `with timeout of 30 seconds` so pathological libraries fail cleanly instead of wedging. The coordinator's live pass measures it on the real library; if slow, the contingency is search-then-filter (documented in the plan). Every OTHER read path uses the dictionary's native `search` command or bounded bulk fetches — no scanning `whose` anywhere.

## Architecture

Established pattern ×3 AppleScript modules + 1 pure-Swift module:

```
Sources/
  Core/              # + MediaModels.swift (TrackItem, PlaylistInfo, PlayerState, TVItem, ShortcutInfo)
  MusicModule/       # MusicStore, MusicActions, MusicScripts, AppleScriptMusicStore, MusicCommand
  TVModule/          # TVStore, TVActions, TVScripts, AppleScriptTVStore, TVCommand
  ShortcutsModule/   # ShortcutStore, ShortcutActions, ShortcutScripts, AppleScriptShortcutStore, ShortcutsCommand
  CallModule/        # CallURLBuilder (pure), CallCommand + FaceTimeCommand (open via injected runner)
```

All AppleScript rules carried: escape every interpolation, `with timeout` on every script, `as list` coercion on bulk fetches, FS/RS records, sentinels, osacompile-verified builders, store-level id-dedupe where enumeration could double-visit, warnIfDropped with nouns.

## Command surface

```
mac music now                              # player state + current track + volume
mac music play [--playlist P | --track-id ID]   # no args = resume
mac music pause | mac music next | mac music prev
mac music volume [0-100]                   # get when omitted, set when given
mac music search "query" [--limit 20]      # native search command, not whose
mac music playlists
mac music playlist-create <name>
mac music playlist-add <playlist> <track-id>
mac music playlist-remove <playlist> <track-id>
mac music playlist-delete <name>
mac music rate <track-id> <0-5>

mac tv now | mac tv pause | mac tv resume
mac tv list [--limit 50]                   # library items: movies/episodes
mac tv play <id>

mac shortcuts list
mac shortcuts run <name> [--input "text"] [--id]   # --id: <name> is a shortcut id

mac call <number> [--dry-run]
mac facetime <handle> [--audio] [--dry-run]
```

- **IDs**: Music/TV `persistent ID` (stable hex); shortcuts have UUID ids. Mutations by exact id/name with ambiguity rejection (playlist names and shortcut names can duplicate → badInput naming candidates; playlists also addressable via the id printed by `playlists`).
- Ratings: user-facing 0–5 stars ↔ dictionary 0–100 (×20), mirroring the ReminderPriority mapping precedent.
- `playlist-delete` only deletes user playlists (kind check) — never library/system playlists; `playlist-add/remove` likewise refuse non-user playlists with badInput.
- All conventions carry over: --json/--quiet, exit 0/1/2 (+64), emitConfirmation for mutations, locked JSON schemas, sorted keys, ISO 8601.

## Models (Core, locked schemas)

- `TrackItem` — id, name, artist, album, durationSeconds (Int), rating (Int 0–5), playlist? (context name, omitted when n/a)
- `PlaylistInfo` — id, name, trackCount, kind ("user"|"system")
- `PlayerState` — state ("playing"|"paused"|"stopped"), volume (Int), track? (TrackItem, omitted when stopped), positionSeconds? (Int)
- `TVItem` — id, name, kind ("movie"|"episode"|"other"), show?, seasonNumber?, episodeNumber?
- `ShortcutInfo` — id, name, folder? 

## Error handling

- Unknown track/playlist/shortcut id or name → notFound with the discovery command named. Ambiguous names → badInput listing candidates (sorted, capped 5).
- volume outside 0–100, rating outside 0–5, empty query/name/handle → badInput.
- Music/TV not running: playback commands LAUNCH the app implicitly (AppleScript tell activates); `now` when player is stopped returns state "stopped" with track omitted — not an error.
- Shortcuts run failures (shortcut threw / not found at run time) → the script returns sentinel-wrapped error text → badInput carrying the shortcut's own error message.
- Call: invalid characters after normalization → badInput; `open` failure → internal envelope.
- Automation consent (-1743) → existing permissionDenied mapping. Doctor gains automation:Music, automation:TV, automation:Shortcuts (target "Shortcuts Events", bundle com.apple.shortcuts.events).

## Testing

- Established stack: mock-backed actions tests (fidelity mocks incl. ambiguity + kind-guard behavior), builder tests (escaping, timeout, sentinels, the single sanctioned whose-by-id shape), store parsing tests (record shapes, dedupe, malformed-row warnings), parse-only CLI tests, osacompile of every builder variant.
- CallURLBuilder is pure Swift: exact-URL tests (digit normalization, percent-encoding, facetime vs facetime-audio), plus --dry-run printing the URL without opening. The open path uses an injected `(URL) throws -> Void` runner; tests assert the runner receives the right URL and that dry-run never calls it.
- Smoke: music read paths + smoke-playlist round-trip; tv list; shortcuts list; call --dry-run. Playback/pause verification: coordinator live pass only.

## Non-goals (v4)

AirPlay control, EQ, queue/up-next manipulation, lyrics, store/streaming search (library only), TV store content, shortcut creation/editing, call state/answering/hangup, SMS via tel scheme, Podcasts/News/Stocks in any form (no API — see scriptability table).

## Known limitations to document

- Music search covers the local/cloud library, not the streaming catalog.
- `whose persistent ID` exception and its timeout bound (and the measured cost on a real library, filled in after the live pass).
- Shortcuts run blocks until the shortcut completes; long-running shortcuts hold the CLI (bounded by the script timeout).
- call/facetime are initiate-only; macOS prompts before dialing; requires iPhone relay/FaceTime sign-in respectively.
- README scriptability table: the no-API apps, with Shortcuts as the documented workaround.
