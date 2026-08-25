# mac-cli Design

**Date:** 2026-08-25
**Status:** Approved

## Purpose

A single, agent-friendly CLI (`mac`) for native macOS apps. Built for Carlton's own agents and workflows (Claude Code, potentially Realm) first, with clean-enough design to open-source later. It replaces the fragmented landscape of per-app tools (`reminders-cli`, `icalBuddy`) and osascript wrappers with one fast, typed, predictable binary.

**Core thesis:** agents want CLIs — composable in bash, discoverable via `--help`, JSON-outputting, with stable exit codes — and the existing osascript-based tools are slow (1–2s per call), stringly-typed, and brittle. Building on native frameworks fixes those caveats.

## Scope

**v1 apps:** Calendar, Reminders (both EventKit), Contacts (Contacts framework).

**Deliberately deferred, architected-for:** Mail, Messages, Notes. These have no public APIs and will ship later as modules that shell out to AppleScript internally, behind the same command surface. Messages reading additionally requires Full Disk Access to `chat.db`.

**Write scope:** full CRUD on all v1 apps. Destructive/mutating commands (`edit`, `delete`, `complete`) accept **only exact native IDs**, never names or fuzzy matches, so a hallucinated title can never hit the wrong item.

## Architecture

- Single Swift executable `mac`, built with `swift-argument-parser`.
- **Target: macOS 14+** — floor chosen for EventKit's modern full-access APIs (`requestFullAccessToEvents` / `requestFullAccessToReminders`), keeping one permission model.
- Swift Package layout:

```
Sources/
  MacCLI/            # entry point, subcommand registration
  Core/              # output formatting, JSON encoding, date parsing, errors, exit codes
  CalendarModule/    # EventKit (events)
  RemindersModule/   # EventKit (reminders)
  ContactsModule/    # Contacts framework
```

- Each module exposes ArgumentParser subcommands and talks to its framework through a protocol (`EventStoreProviding`, `ContactStoreProviding`) so unit tests can inject mocks.
- Future AppleScript-backed modules (Mail/Messages/Notes) conform to the same conventions; the hybrid backend is invisible to callers.

### TCC / Info.plist embedding

TCC requires usage-description strings (`NSCalendarsFullAccessUsageDescription`, `NSRemindersFullAccessUsageDescription`, `NSContactsUsageDescription`) that normally live in an app bundle's Info.plist. For a bare CLI binary, embed the plist into the executable with linker flags (`-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker <path>`). Without this, permission prompts never appear and framework calls silently fail. This is a hard requirement of the build, not an optimization.

## Command surface

```
mac calendar list      [--from today] [--to +7d] [--calendar Work]
mac calendar add       "Dentist" --at "tomorrow 2pm" [--duration 1h] [--calendar] [--location] [--notes] [--all-day]
mac calendar edit      <id> [--title|--at|--duration|--location|--notes]
mac calendar delete    <id>
mac calendar calendars                  # enumerate calendars

mac reminders list     [--list Groceries] [--include-completed] [--due-before friday]
mac reminders add      "Buy milk" [--list] [--due "tomorrow 9am"] [--notes] [--priority high]
mac reminders complete <id>
mac reminders edit     <id> [...]
mac reminders delete   <id>
mac reminders lists

mac contacts find      "Sarah"          # search name/email/phone
mac contacts show      <id>             # full card
mac contacts add       --name "..." [--phone] [--email] [--org]
mac contacts edit      <id> [...]
mac contacts delete    <id>

mac doctor                              # permission audit + exact fix steps
```

- **Global flags:** `--json`, `--quiet` on every command.
- **IDs:** native framework identifiers (EventKit `calendarItemIdentifier`, Contacts `identifier`), printed in every list row so an agent's read→act loop needs no extra lookup.
- **Dates:** small built-in parser (~150 lines, table-driven tests, no dependency) accepting:
  - ISO: `2026-08-27 14:00`, `2026-08-27`
  - Naturals: `today`, `tomorrow`, `tomorrow 9am`, `friday`
  - Offsets: `+7d`, `+2h`
- **`--help`** on every subcommand includes usage examples (agents read help text).

## Output & errors

- **Human (default):** one item per line — `id  title  when` — no tables, no color dependencies.
- **`--json`:** stable documented schema, camelCase keys, arrays of objects, dates as ISO 8601 with timezone offset.
- **Errors:** written to stderr, always actionable — e.g. `Calendar access not granted. Run: mac doctor` — never raw framework errors. With `--json`: `{"error": {"code": "permissionDenied", "message": "..."}}`.
- **Exit codes:** `0` success · `1` not found / bad input · `2` permission denied. Agents branch on codes without parsing text.

### `mac doctor`

Checks authorization status for Calendar, Reminders, and Contacts. For each capability prints granted / denied / not-yet-asked plus the exact System Settings path to fix it. Later grows checks for Automation consent and Full Disk Access when Mail/Messages ship.

## Testing

- **Unit tests (CI-safe):** date parser, JSON schema stability, human formatting, argument parsing — all against mocked store protocols; no TCC permissions needed.
- **Integration smoke test (local-only):** a script that runs the real binary against a dedicated `mac-cli-test` calendar/reminder list it creates and tears down, exercising the full CRUD cycle. Not run in CI; run before tagging a release.

## Distribution

- Repo: `Projects/mac-cli`, binary named `mac`. MIT license from day one.
- v1 install: `swift build -c release` + `make install` (copies to `/usr/local/bin`).
- If open-sourced: Homebrew tap, then codesign + notarize (pipeline already familiar from MCP Manager).

## Non-goals (v1)

- Mail, Messages, Notes modules (deferred; architecture accommodates them).
- Delete-by-name or any fuzzy-matched mutation.
- TUI, colors, tables, or interactive prompts — this is a plumbing tool.
- Windows/Linux anything.
