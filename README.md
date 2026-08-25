# mac

An agent-friendly CLI for native macOS apps. Calendar, Reminders, and Contacts today — built on EventKit and the Contacts framework, not AppleScript, so calls run in milliseconds with typed errors and stable IDs.

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

## Usage

```sh
mac calendar list --from today --to +7d
mac calendar add "Dentist" --at "tomorrow 2pm" --duration 1h
mac reminders add "Buy milk" --list Groceries --due "tomorrow 9am"
mac reminders complete <id>
mac contacts find "Sarah"
```

Every command supports `--json`. Dates accept ISO (`2026-08-27 14:00`), naturals (`tomorrow 2pm`, `friday`), and offsets (`+7d`, `+2h`).

## For agents

- `--json` on every command; sorted keys, ISO 8601 dates; schemas are stable.
- Exit codes: `0` success, `1` not found / bad input, `2` permission denied.
- Mutations (`edit`, `delete`, `complete`) take exact IDs only — get IDs from `list`/`find`.
- Errors are actionable one-liners on stderr; `mac doctor` reports missing permissions with fix steps.
- Malformed invocations (unknown flags, missing required options) exit `64` (BSD EX_USAGE); `1` is reserved for semantic errors — not found or bad input.
- `--json` always prints, even with `--quiet`; `--quiet` suppresses human-readable output only.

## Known limitations (v1)

- **Recurring events** share one ID across all occurrences; `edit`/`delete` act on the series master, not a specific occurrence.
- **Date-only due dates** get a time of midnight — every reminder due date carries a time.
- **Duplicate calendar/list names** (e.g. "Personal" in two accounts) resolve to the first match.
- Contact phone/email labels (mobile/work/home) are flattened to plain values.
- **No clear-to-nil:** edit flags replace values. A due date, once set, cannot be removed; notes/location/org can be blanked by passing an empty string. Names and titles cannot be set to empty.

## Roadmap

Mail, Messages, and Notes modules (AppleScript-backed behind the same command surface).

## License

MIT
