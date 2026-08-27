# mac-cli v3 Design — Notes

**Date:** 2026-08-27
**Status:** Approved
**Builds on:** v1 (Calendar/Reminders/Contacts, shipped) and v2 (Mail/Messages, shipped)

## Purpose

Add the last roadmap module: **Notes**, completing the command surface promised in the v1 spec. Full CRUD via Notes.app's AppleScript dictionary — the only viable backend, since NoteStore.sqlite stores bodies as gzipped protobuf blobs (verified live: content is not readable via SQLite, and writing it is out of the question).

## Live measurements that shaped this design (Carlton's machine)

- 163 notes across 6 accounts (iCloud + 5 mail accounts); iCloud alone has ~20 folders.
- AppleScript is FAST at this scale: all-note bulk metadata fetch ~1s; even `whose` returns in 1s. Unlike Mail (100k messages), performance is a non-issue — but the module still avoids `whose` and uses bulk-fetch + Swift-side filtering for consistency and safety on larger stores.
- Notes exposes BOTH `body` (HTML) and `plaintext` properties — no lossy conversion needed on our side.
- Folder names collide across accounts (several accounts each have a folder literally named "Notes").
- Every account has a "Recently Deleted" folder that would pollute listings.

## Scope decisions (settled during brainstorming)

- **Full CRUD** (list/search/read/add/append/edit/delete + folders). `delete` moves notes to Recently Deleted via AppleScript — recoverable, not a hard delete.
- **Plain text by default; `--html` opt-in** on `read` for the raw body. Writes accept plain text; Notes renders it.
- **Folder addressing by name with ambiguity rejection** — a folder name that matches in multiple accounts errors, naming the candidates and pointing at `--account` (same pattern as Messages handle ambiguity, which caught a real collision live).
- **"Recently Deleted" excluded** from `list`, `search`, and `folders` output unless explicitly requested via `--folder "Recently Deleted"`.
- `add` without `--folder`/`--account` targets the default account's default folder.

## Architecture

Same pattern as the five shipped modules — store protocol → mock-tested actions → AppleScript adapter → subcommands:

```
Sources/
  Core/            # + NoteItem, NoteFolderInfo models
  NotesModule/     # NoteStore, NoteActions, NoteScripts, AppleScriptNoteStore, NotesCommand
```

- **NoteScripts**: pure AppleScript source builders. Every user value passes through `AppleScript.escape`; every script wrapped in `with timeout of 600 seconds`; **no `whose` clauses anywhere** (hard invariant carried from the Mail redesign, enforced by test). Bulk property fetches (`name of every note of f`, etc.) with Swift-side filtering.
- **AppleScriptNoteStore**: executes builders via `AppleScript.run` (targetName "Notes"), parses FS/RS records, maps sentinels (`NOTFOUND`, ambiguity handled Swift-side) to MacErrors.
- **NoteActions**: validation (limits 1...500, non-empty title/query/text), folder resolution + ambiguity rejection, Recently Deleted filtering, sorting (modified, newest first).

## Command surface

```
mac notes list    [--folder Ideas] [--account iCloud] [--limit 20]
mac notes search  "query" [--folder] [--account] [--limit 20]   # matches title AND body text
mac notes read    <id> [--html]
mac notes add     "Title" --body "..." [--folder] [--account]
mac notes append  <id> "text"
mac notes edit    <id> [--title T] [--body B]                   # --body replaces the body
mac notes delete  <id>
mac notes folders [--account]
```

- **IDs are Notes' AppleScript `id`** (Core Data URL form, e.g. `x-coredata://.../ICNote/p123`) — stable and exact; mutations by exact ID only, per project convention.
- All v1/v2 conventions carry over: `--json`/`--quiet` (JSON always prints), exit codes 0/1/2 (+64 usage), one human line per item, confirmations via `Output.emitConfirmation`.
- `list`/`search` sort by modification date, newest first.
- `edit` requires at least one of `--title`/`--body` (else badInput); empty-string title rejected (same guard as the other modules).
- `append` appends a new paragraph to the existing body.

## Models (Core, locked JSON schemas)

- **`NoteItem`** — `id`, `title`, `folder`, `account`, `created`, `modified`, `body?` (populated by `read` only, omitted elsewhere — mirrors `EmailItem`). With `--html`, `body` carries the raw HTML instead of plaintext.
- **`NoteFolderInfo`** — `id`, `name`, `account`, `noteCount`.

Same encoder conventions: sorted keys, ISO 8601 dates, nil-omitting, exact-string schema tests.

## Error handling

- Unknown id / folder / account → `notFound` with an actionable hint (`Run: mac notes folders`).
- Ambiguous folder name → `badInput` naming the account candidates and pointing at `--account` (candidates sorted, capped at 5).
- Empty title/query/append text, both edit flags absent, limit out of range → `badInput`.
- `add` with `--account` but no `--folder` → `badInput` (there is exactly one default folder; an account alone is not a target).
- Automation consent denied → the runner's existing `permissionDenied` (-1743) mapping; `mac doctor` gains an `automation:Notes` row.
- Unmapped AppleScript failures → existing `internal` envelope.

## Doctor

One new row: `automation:Notes` (bundle id `com.apple.Notes`), using the existing `automationRow` helper and `unknown`-state semantics.

## Testing

- **NoteActions**: mock-backed tests — folder ambiguity rejection, unique-name resolution, `--account` disambiguation, Recently Deleted excluded by default and includable explicitly, newest-first sorting, all badInput/notFound paths, permissionDenied propagation.
- **NoteScripts**: builder tests asserting escaping of interpolated values, `with timeout` present, sentinels, and the no-`whose` invariant; `osacompile` compile-check of every generated script (compile-only).
- **Store parsing**: record-shape tests via `AppleScript.parseRecords` fixtures (6-field list rows, 7-field read rows).
- **Smoke test**: new `== notes ==` section — add a note titled "mac-cli smoke note", append to it, edit its title, read it back (assert body text), delete it (lands in Recently Deleted), and `notes folders` sanity check. Live verification includes real emoji folder names (present in Carlton's iCloud account).

## Non-goals (v3)

- Attachments, images, drawings; checklists as structured data (they read as plain lines); tags/mentions; rich text formatting on write; note sharing/collaboration state; hard delete or emptying Recently Deleted; locked-note contents (see limitations).

## Known limitations to document in README

- **Password-protected notes** cannot be read via AppleScript — they appear in listings but `read` returns an empty body.
- `delete` moves to Recently Deleted (recoverable in Notes.app) rather than erasing.
- Folder names are resolved per-name; duplicates across accounts require `--account`.
- Checklists and attachments flatten to plain text (attachment placeholders may appear as blank lines).
