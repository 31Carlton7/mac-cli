# mac

An agent-friendly CLI for native macOS apps. Calendar, Reminders, and Contacts run on native frameworks (EventKit, Contacts) for millisecond calls with typed errors and stable IDs; Mail and Messages use AppleScript and a read-only Messages database, since Apple ships no public APIs for them.

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

Mail and Messages additionally need Automation consent (prompted on first use) and, for reading Messages history, Full Disk Access for your terminal app — `mac doctor` reports all of it with fix steps.

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
```

Every command supports `--json`. Dates accept ISO (`2026-08-27 14:00`), naturals (`tomorrow 2pm`, `friday`), and offsets (`+7d`, `+2h`).

## For agents

- `--json` on every command; sorted keys, ISO 8601 dates; schemas are stable.
- Exit codes: `0` success, `1` not found / bad input, `2` permission denied.
- Mutations (`edit`, `delete`, `complete`, `mark-read`, `archive`) take exact IDs only — get IDs from `list`/`find`.
- Errors are actionable one-liners on stderr; `mac doctor` reports missing permissions with fix steps.
- Malformed invocations (unknown flags, missing required options) exit `64` (BSD EX_USAGE); `1` is reserved for semantic errors — not found or bad input.
- `--json` always prints, even with `--quiet`; `--quiet` suppresses human-readable output only.
- Prefer `mac mail draft` over `mac mail send` unless the user explicitly asked to send.
- `mac messages send` takes exact handles only — resolve names with `mac contacts find` first.

## Known limitations

- **Recurring events** share one ID across all occurrences; `edit`/`delete` act on the series master, not a specific occurrence.
- **Date-only due dates** get a time of midnight — every reminder due date carries a time.
- **Duplicate calendar/list names** (e.g. "Personal" in two accounts) resolve to the first match.
- Contact phone/email labels (mobile/work/home) are flattened to plain values.
- **No clear-to-nil:** edit flags replace values. A due date, once set, cannot be removed; notes/location/org can be blanked by passing an empty string. Names and titles cannot be set to empty.
- Mail search matches subject/sender only (no body search); reads are scoped to account inboxes.
- Mail list ordering depends on Mail.app's own enumeration; `mac` over-fetches and re-sorts newest-first, which is reliable for typical inboxes but not guaranteed for very large unread counts.
- Mail composition is plain-text; no attachments.
- Messages: group chats are read-only.
- `mac messages history` accepts an exact handle or, failing that, an unambiguous 10+ digit variant; a variant matching more than one conversation is rejected rather than guessed.
- `mac messages send` requires an exact handle — it does no normalization.
- **A successful `mac messages send` is not proof of delivery.** Messages accepts sends to handles that were never registered with iMessage (typos, SMS-only contacts) without a synchronous error. Verify by reading the thread back with `mac messages history`.

## Roadmap

Notes module (AppleScript-backed behind the same command surface).

## License

MIT
