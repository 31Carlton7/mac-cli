# mac-cli v2 Design — Mail + Messages

**Date:** 2026-08-25
**Status:** Approved
**Builds on:** `2026-08-25-mac-cli-design.md` (v1, shipped)

## Purpose

Extend `mac` with the two apps flagged "very high on the radar" in the v1 spec: **Mail** and **Messages**. This is the first use of the AppleScript-backed store path the v1 architecture reserved, plus a direct SQLite read path for Messages history. Carlton uses Mail.app with his accounts configured, so both modules serve his own agents first.

**Capability summary:** read/search/triage email, compose drafts and send email; read iMessage conversations and history, send iMessages.

## Scope decisions (settled during brainstorming)

- **Outbound:** both `mail draft` (compose in Mail.app for human review — the documented default for agents) AND `mail send`, plus `messages send`. No artificial `--confirm` flags; the agent harness's own command gating is the guardrail.
- **Messages read:** full read (conversations + history) via `chat.db`, with Full Disk Access as a documented prerequisite.
- **Mail management:** read + compose + light triage (`mark-read`, `archive`). **No mail delete** — consistent with v1 caution.
- **Send targets are exact handles only** (phone number or iMessage email address). No fuzzy name resolution — agents resolve names via `mac contacts find` first. Group chats: readable, not sendable.

## Architecture

Same pattern as v1 — store protocol → mock-tested actions → real adapter → subcommands:

```
Sources/
  Core/                 # + AppleScriptRunner.swift, EmailItem/MessageItem/ConversationInfo models
  MailModule/           # MailStore, MailActions, AppleScriptMailStore, MailCommand
  MessagesModule/       # MessageStore, MessageActions, ChatDBReader + AppleScript sender, MessagesCommand
```

### AppleScriptRunner (Core)

- Script **construction** is pure string functions using a strict escaping helper (escapes `\` then `"`; newlines passed through as escaped `\n` inside AppleScript string literals). Escaping is the injection surface and is fully unit-tested.
- Script **execution** via `NSAppleScript` in-process. Error mapping:
  - AppleEvent error **-1743** (Automation consent denied) → `MacError(.permissionDenied, …)` pointing at System Settings > Privacy & Security > Automation and `mac doctor`.
  - Target app unavailable → actionable `MacError`.
  - Anything else → existing `internal` JSON envelope via `withErrorHandling`.

### ChatDBReader (MessagesModule)

- Opens `~/Library/Messages/chat.db` with `SQLITE_OPEN_READONLY` (never writes; never blocks Messages.app).
- Tables: `message`, `handle`, `chat`, `chat_message_join`, `chat_handle_join`.
- **`attributedBody` decoding:** modern macOS stores many message bodies as a `typedstream` blob with NULL `text`. Reader decodes the blob to plain text (NSAttributedString/typedstream unarchive), falling back to the literal string `⟨unsupported content⟩` when undecodable. `text` column wins when non-NULL.
- **Apple-epoch dates:** stored as nanoseconds since 2001-01-01; converted to `Date` (with the seconds-scale legacy format handled if encountered).

### The Messages store is hybrid

`MessageStore` protocol methods: reads are served by ChatDBReader, `send` by AppleScriptRunner. Invisible to callers — exactly the seam v1's design reserved.

## Permission model

Two new permission types, both surfaced in `mac doctor`:

| Capability | Mechanism | Doctor check |
|---|---|---|
| `automation:Mail` | AppleEvents consent, per target app | `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` — no prompt |
| `automation:Messages` | same | same |
| `fullDiskAccess` | required to read `chat.db` | empirical: attempt read-only open of chat.db; failure → denied with Settings path |

- Embedded Info.plist gains `NSAppleEventsUsageDescription`.
- Documented caveat (carried from v1): grants attach to the terminal app. Live use happens from Terminal; agent-hosted shells get clean exit-2 permission errors.

## Command surface

```
mac mail unread    [--account Work] [--limit 20]
mac mail search    "invoice" [--limit 20]
mac mail read      <id>
mac mail draft     --to a@b.com --subject "…" --body "…" [--cc x@y.com]
mac mail send      --to a@b.com --subject "…" --body "…" [--cc x@y.com]
mac mail mark-read <id>
mac mail archive   <id>

mac messages chats            [--limit 20]
mac messages history <handle> [--limit 30]
mac messages send    <handle> "text"
```

- **Mail IDs are RFC `message id` headers** (globally unique, stable across restarts). Lookup via Mail's native `whose message id is` filtering, scoped to the inbox of each enabled account.
- All v1 conventions carry over: `--json`/`--quiet` on everything (JSON always prints), exit codes 0/1/2 (+64 for usage errors), mutations by exact ID, human output one line per item.
- `mail draft` creates a **visible** outgoing message in Mail.app and does not send. `mail send` composes and sends. Plain-text bodies only.
- `messages history` returns oldest→newest within the limit window (natural reading order).
- `messages send` uses the iMessage service; SMS relay is best-effort and documented as such.

## Models (Core, locked JSON schemas)

- **`EmailItem`** — `id`, `subject`, `from`, `date`, `isRead`, `account`, `body?` (populated by `mail read` only; omitted elsewhere).
- **`MessageItem`** — `id` (chat.db guid), `chat`, `sender` (handle, or `"me"` when `isFromMe`), `text`, `date`, `isFromMe`.
- **`ConversationInfo`** — `id` (chat identifier), `name` (display name or counterpart handle), `lastActivity`, `isGroup`.

Same encoder conventions as v1: sorted keys, ISO 8601 dates, nil-omitting, exact-string schema tests.

## Error handling

- Every store method throws `MacError` for the mapped cases (permission, not-found, bad input); unmapped AppleScript/SQLite failures flow to the `internal` JSON envelope — the contract v1 hardened.
- `mail read <unknown-id>` / `mail archive` on a missing message → `notFound`.
- `mail archive` when the account has no Archive mailbox → `notFound` with a message naming the account.
- `messages send` to a handle with no iMessage account reachable → mapped from the AppleScript error to an actionable `badInput`/`internal` message.
- Empty `--subject`+`--body` both empty on send → `badInput`; empty message text → `badInput`.

## Testing

- **Actions layers:** mock-backed unit tests, v1 pattern — including mock/real fidelity for error paths (unknown IDs, permission denial), the lesson v1 learned twice.
- **AppleScript builders:** pure functions; tests assert exact generated script strings, including escaping of `"`, `\`, and newlines embedded in user input (injection tests).
- **ChatDBReader:** unit tests build a fixture `chat.db` in a temp directory with the real schema — seeded rows including a NULL-`text`/`attributedBody` row and Apple-epoch nanosecond dates — so SQL and decoding run for real in CI-safe tests, no FDA required.
- **Smoke test:** `scripts/smoke.sh` gains mail + messages sections: mail unread/search (read path) plus a draft with a self-describing "safe to close" subject (deleting drafts via AppleScript is unreliable, so the user closes it); `messages send` to the user's **own handle** via `SMOKE_HANDLE` (self-message), verified by reading it back via `messages history`. Run from Terminal like v1's.

## Non-goals (v2)

- Attachments (either app), HTML mail composition, mail body-text search, mail delete.
- Group-chat sending, Messages unread counts, tapbacks/reactions/edits.
- Notes module (v3 candidate), Homebrew/GitHub distribution (separate track).

## Known limitations to document in README

- Mail search covers subject/sender only (AppleScript body search is unusably slow).
- Mail reads are scoped to each account's inbox.
- Messages send requires an exact handle; agents resolve names via `mac contacts find`.
- SMS relay sends are best-effort; group chats are read-only.
- Full Disk Access and per-app Automation consent are new prerequisites; `mac doctor` reports all of them.
