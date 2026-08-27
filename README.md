# mac

**[macoscli.sh](https://macoscli.sh)**

An agent-friendly CLI for native macOS apps. Calendar, Reminders, and Contacts run on native frameworks (EventKit, Contacts) for millisecond calls with typed errors and stable IDs; Mail, Messages, Notes, Music, TV, and Shortcuts use AppleScript (and a read-only Messages database), since Apple ships no public APIs for them.

Built for AI agents (Claude Code, etc.) and the humans who drive them: every command has `--json`, stable exit codes, and `--help` with examples.

## Install

```sh
make install        # builds release binary, installs to /usr/local/bin/mac
```

Requires macOS 14+ and Xcode command line tools.

## First run

macOS will prompt once per capability (Calendar, Reminders, Contacts) the first time you use it. Check status anytime:

```sh
mac doctor
```

Mail, Messages, Notes, Music, TV, and Shortcuts additionally need Automation consent (prompted on first use) and, for reading Messages history, Full Disk Access for your terminal app — `mac doctor` reports all of it with fix steps.

## Usage

```sh
mac calendar list --from today --to +7d
mac calendar add "Dentist" --at "tomorrow 2pm" --duration 1h
mac reminders add "Buy milk" --list Groceries --due "tomorrow 9am"
mac reminders complete <id>
mac contacts find "Sarah"
mac mail accounts
mac mail unread --limit 10
mac mail search "invoice"
mac mail draft --to a@b.com --subject "Hi" --body "..."
mac messages history +15551234567
mac messages send +15551234567 "Running 10 min late"
mac notes list --folder Ideas
mac notes search "brunch"
mac notes add "Meeting notes" --body "Attendees: ..." --folder Work
mac notes append <id> "one more thing"
mac music play --playlist Workout
mac music search "here comes the sun" --limit 5
mac music playlist-add Workout <trackID>
mac tv list --limit 10
mac tv play <id>
mac shortcuts run "Get Weather"
mac call "+1 555 123 4567"
mac facetime user@example.com --audio
mac finder selection
mac finder reveal ~/Downloads/report.pdf
mac finder trash ~/Downloads/old-draft.pdf
mac finder disks
```

Every command supports `--json`. Dates accept ISO (`2026-08-27 14:00`), naturals (`tomorrow 2pm`, `friday`), and offsets (`+7d`, `+2h`).

## For agents

- `--json` on every command; sorted keys, ISO 8601 dates; schemas are stable.
- Exit codes: `0` success, `1` not found / bad input, `2` permission denied.
- Mutations (`edit`, `delete`, `complete`, `mark-read`, `archive`) take exact IDs only — get IDs from `list`/`find`.
- Discovery commands: `mac calendar calendars` and `mac reminders lists` return objects (`{id,title,kind}`); `mac mail accounts` returns a plain string array, since a Mail account's name is its identifier.
- Errors are actionable one-liners on stderr; `mac doctor` reports missing permissions with fix steps.
- Malformed invocations (unknown flags, missing required options) exit `64` (BSD EX_USAGE); `1` is reserved for semantic errors — not found or bad input.
- `--json` always prints, even with `--quiet`; `--quiet` suppresses human-readable output only.
- Prefer `mac mail draft` over `mac mail send` unless the user explicitly asked to send.
- `mac messages send` takes exact handles only — resolve names with `mac contacts find` first.
- `mac call`/`mac facetime` are initiate-only; macOS confirms before dialing.
- `mac shortcuts run` is the escape hatch for unscriptable apps: wrap the task in a Shortcut and run it by name or id.
- `mac finder trash` is the recoverable delete: the item goes to the Trash, same as dragging it there in Finder, and can be restored until the Trash is emptied — prefer it over `rm` for user files.

## Known limitations

- **Recurring events** share one ID across all occurrences; `edit`/`delete` act on the series master, not a specific occurrence.
- **Date-only due dates** get a time of midnight — every reminder due date carries a time.
- **Duplicate calendar/list names** (e.g. "Personal" in two accounts) resolve to the first match.
- Contact phone/email labels (mobile/work/home) are flattened to plain values.
- **No clear-to-nil:** edit flags replace values. A due date, once set, cannot be removed; notes/location/org can be blanked by passing an empty string. Names and titles cannot be set to empty.
- **Mail reads are windowed.** Every read (`unread`, `search`, `read`, `mark-read`, `archive`) examines only the newest `--scan` messages (default 30) of each account's inbox. A message older than that window is invisible to `mac` — raise `--scan` (max 500) to look further back. AppleScript's `whose` filtering, which would search the whole mailbox, is unusable: on a 97k-message unified inbox it pins Mail.app at 98% CPU indefinitely.
- **Without `--account`, `mac mail unread` is a fast sample, not a global newest-N.** Accounts are scanned smallest-inbox-first and scanning stops as soon as `--limit` is filled, so unread mail sitting in a large account may be omitted while a small account still has results. Pass `--account` for a deterministic per-account listing.
- Mail search matches subject/sender only (no body search), and only within that same `--scan` window.
- **Large mailboxes are slow.** Cost scales with messages touched: roughly 0.15s/message on a 1.7k-message account and ~1.5s/message on a 50k-message one. Keep `--scan` small on big accounts.
- Mail composition is plain-text; no attachments.
- Messages: group chats are read-only.
- `mac messages history` accepts an exact handle or, failing that, an unambiguous 10+ digit variant; a variant matching more than one conversation is rejected rather than guessed.
- `mac messages send` requires an exact handle — it does no normalization.
- **A successful `mac messages send` is not proof of delivery.** Messages accepts sends to handles that were never registered with iMessage (typos, SMS-only contacts) without a synchronous error. Verify by reading the thread back with `mac messages history`.
- Notes: password-protected notes appear in listings but their bodies read as empty; `delete` moves to Recently Deleted (recoverable) rather than erasing; folder names are resolved per-name, so duplicates across accounts need `--account`; checklists and attachments flatten to plain text.
- **`mac music search`/`mac music playlists` see your library, not the Apple Music catalog.** Songs you haven't added won't turn up in search, and Apple Music's `whose`-based library search is unusable at scale (the same measured cost that ruled out `whose` for Mail) — `mac music` and `mac tv` resolve a track/playlist by id via the one sanctioned `whose persistent ID is "<id>"` lookup, run under a 30s timeout, since that shape stayed fast in measurement.
- `mac shortcuts run` blocks until the shortcut finishes; a shortcut that shows its own dialogs or waits on user input will hang the command until that shortcut completes.
- `mac call`/`mac facetime` only open a `tel:`/`facetime:` URL — they never place the call themselves; macOS still asks you to confirm before dialing.
- **`mac finder` is trash-only, by design.** It moves files to the Trash (recoverable); it does not copy, move, rename, or permanently delete. It reflects and drives Finder's GUI state (selection, reveal, open, disks, eject) — for bulk or scripted file operations, use your shell.

## Scriptability of other Apple apps

A survey of remaining first-party apps not yet covered by `mac`, for anyone weighing whether to script them directly or via `mac shortcuts run`. (Finder shipped in v5 — see Usage above.)

| App | Status | Notes |
| --- | --- | --- |
| Photos | Scriptable, not yet wired up | Has a real AppleScript dictionary; candidate for a future module. |
| QuickTime Player | Scriptable, not yet wired up | Recording/playback are scriptable. |
| Preview | Scriptable, not yet wired up | Limited but real dictionary (open/print/close). |
| TextEdit | Scriptable, not yet wired up | Full document AppleScript support. |
| Keynote / Pages / Numbers | Scriptable, not yet wired up | Rich iWork dictionaries; planned for v6. |
| Podcasts | No public API | Wrap the task in a Shortcut and run it with `mac shortcuts run`. |
| News | No public API | Same workaround. |
| Stocks | No public API | Same workaround. |
| FaceTime / Phone (beyond dialing) | No public API | `mac call`/`mac facetime` cover initiating a call; anything past that needs the Shortcuts workaround. |
| Maps | No public API | Same workaround. |
| Weather | No public API | Same workaround. |
| Books | No public API | Same workaround. |
| Voice Memos | No public API | Same workaround. |
| Freeform | No public API | Same workaround. |
| Journal | No public API | Same workaround. |
| Home | No public API | Same workaround. |
| Passwords | No public API | Same workaround. |

## Roadmap

iWork — Keynote/Pages/Numbers (v6), Homebrew tap.

## License

MIT
