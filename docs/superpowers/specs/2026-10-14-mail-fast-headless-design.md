# mac-cli 0.7 design: Mail, fast and headless

**Date:** 2026-10-14
**Status:** Proposed
**Builds on:** v2 Mail (AppleScript window scanning, revised 2026-08-27)

## Purpose

`mac mail` is the slowest and narrowest module. Every read drives Mail.app through AppleScript, sees only the newest `--scan` messages of each inbox, and searches subject and sender only. The feedback that prompted this release: make `mac mail` faster, more flexible, and headless.

0.7 reads Mail's own local database and message files directly, so reads never touch Mail.app. Writes still go through Mail.app, but they target one exact message instead of scanning a window. On top of that base it adds the commands an agent needs to do real mail work.

## Live measurements that shaped this design (my machine)

- 5 accounts (4 Gmail, 1 Exchange), about 107k messages, a 256 MB Envelope Index, a 5.4 GB message store.
- 0.6 `mac mail unread`: 23 to 88 s. `mac mail search`: 271 s and 524 s for two runs (stopped there).
- Reading the same data from the Envelope Index (prototyped in another CLI on this machine): 12 to 60 ms per command, with no Mail.app calls.
- One SQLite query in process: 0.02 to 0.1 ms. Spawning `sqlite3` for it: 5.5 to 8 ms. Use `SQLite3` in process, as `ChatDBReader` already does.
- Asking Mail.app for its account list: 330 to 400 ms, and 1 to 12 s while Mail is busy. It was the largest cost on every read.
- `mdfind` returns no Mail messages: Mail's Spotlight data is private. Grepping the raw message files took 159 s and misses base64 bodies. Body search needs its own index.

## Architecture

```
Sources/MailModule/
  EnvelopeIndex.swift        read-only SQLite reader over Mail's Envelope Index
  IndexMailStore.swift       MailStore reads backed by the index and message files
  MailAccountDirectory.swift account name <-> id, cached against the system account store
  EmlxMessage.swift          .emlx/.partial.emlx locate + RFC 822/MIME decoding
  AppleScriptMailStore.swift writes, and the read fallback when the index is unavailable
```

**Reads** use the index and `.emlx` files only. When the index cannot be opened (no Full Disk Access, missing file, unexpected schema), reads fall back to the 0.6 AppleScript window store and print one notice on stderr naming `mac doctor`. The fallback never runs silently, and it is never used to answer "not found" for a message the index could not see.

**Writes** resolve the target message in the index first: its account, its mailbox, and Mail's numeric message id. Then one Mail.app script acts on exactly that message, by id. Several ids in one command run as one script per account. `whose` stays banned.

### Message ids

The id contract is unchanged: a message's id is its RFC `Message-ID` without angle brackets, as 0.6 emitted it. Input accepts it with or without brackets.

The index stores the header bracketed, in `message_global_data.message_id_header`, joined by `messages.global_message_id`. On this machine 106,285 of 106,301 messages have it. 268 ids appear on more than one live row (copies across mailboxes).

- **Reads** pick the inbox row, then the newest row.
- **Writes** need exactly one row in the action's source scope. Zero rows is `notFound`. More than one is `badInput` naming the mailboxes and pointing at `--mailbox`. Never guess a mutation target.

### Envelope Index facts

- Path: the newest `~/Library/Mail/V*/MailData/Envelope Index`. Do not hard-code `V10`.
- Mailbox URLs are `imap://<accountId>/<path>` for IMAP (including Gmail and iCloud) and `ews://<accountId>/<path>` for Exchange. Paths are percent-encoded (`Sent%20Items`, `%5BGmail%5D/All%20Mail`). Code that builds only `imap://` silently loses Exchange.
- The inbox is `INBOX` on IMAP and `Inbox` on Exchange. Match it with `lower(url) = lower(?)`. Never write OR-ed `url = ? collate nocase` terms: `mailboxes.url` carries a binary `UNIQUE` index, and on SQLite 3.54 that form returns no rows. Test fixtures must declare `url TEXT COLLATE BINARY NOT NULL, UNIQUE(url)` so they catch it.
- Gmail stores each message once in `[Gmail]/All Mail` and records its other mailboxes in `labels(message_id, mailbox_id)`. A message is in mailbox X when `m.mailbox = X` or a `labels` row says so. All Mail and Archive count backing rows only.
- `messages`: `ROWID` (Mail's numeric message id), `mailbox`, `subject` → `subjects`, `sender` → `addresses(address, comment)`, `summary` → `summaries`, `date_sent`/`date_received` (Unix seconds), `read`, `flagged`, `deleted`, `size`, `conversation_id`, `global_message_id`.
- `recipients(message, address, type, position)`, `attachments(message, attachment_id, name)`.
- `message_global_data`: `message_id_header`, `model_category` (Mail's on-device category, set on 96% of messages here), `generated_summary` (Apple Intelligence, sparse), `urgent`, `read_later_date`, `send_later_date`, follow-up dates.
- Search the small tables first (`subjects`, `addresses`, `summaries`), then `IN` on `messages`, ordered by `date_received desc` with a limit. For rare terms this is about 3× faster than joining first.

### Accounts

Mail's account ids equal `ZACCOUNT.ZIDENTIFIER` in `~/Library/Accounts/Accounts4.sqlite`. The name ↔ id map comes from one Mail.app call. It is cached together with a hash of the account store's account rows and enabled-dataclass rows, and reused only while that hash is unchanged. A name the cache does not know asks Mail.app again before anything reports `notFound`.

### Message files

Path: `~/Library/Mail/V*/<accountId>/<mailbox path>.mbox/<store id>/Data/…/Messages/<ROWID>.emlx`, or `<ROWID>.partial.emlx` when the attachments were stored separately (35% of files here). Resolve paths from the mailbox URL and verify them against disk.

An `.emlx` file is a decimal byte count on its own line, then the RFC 822 message, then a property list. Decoding:
- `multipart/alternative`: prefer `text/plain`, otherwise convert HTML to text.
- Transfer encodings: quoted-printable and base64.
- Charsets, including RFC 2047 encoded-words in headers.

### Output

`EmailItem` keeps every 0.6 key (`id, subject, from, date, isRead, account, body`). New keys are added only where the value is known: `mailbox, to, cc, isFlagged, hasAttachments, isPriority, category, summary`. JSON keys stay sorted and dates stay ISO 8601, as `Output` already does.

## Command surface

Existing commands keep their names and output. On the index they no longer need `--scan`: it is accepted and ignored, and the fallback still honors it. `unread` without `--account` becomes a deterministic newest-N across all accounts.

| Command | Does |
|---|---|
| `list [--account] [--mailbox] [--unread] [--flagged]` | newest messages of any mailbox |
| `mailboxes [--account]` | mailboxes with unread and total counts |
| `mark-unread`, `flag`, `unflag`, `delete`, `move --to` | exact ids, several per call, `--dry-run` |
| `copy --to` | copy to a mailbox; on Gmail this adds a label |
| `mailboxes create|rename|delete` | mailbox management; delete refuses a non-empty mailbox |
| `junk`, `not-junk` | Mail's junk marking |
| `reply [--all]`, `forward --to` | draft by default, `--send` to send |
| `open ID` | show the message in Mail.app |
| `senders [--unread] [--by domain]` | who sends the most mail |
| `contacts QUERY` | addresses you have exchanged mail with |
| `extract ID [--codes] [--links] [--unsubscribe]` | verification codes, links, unsubscribe targets |
| `unsubscribe ID` | dry run unless `--yes`; a `mailto:` target becomes a draft unless `--send` |
| `wait QUERY [--timeout]` | block until a matching message arrives, then print it |
| `watch [QUERY]` | stream new matching messages as JSON lines |
| `index [build|status|clear]` | the local body-search index |
| `draft`, `send` | gain `--html`, `--markdown`, `--attach` |

### Search operators

`search`, `list`, `wait` and `watch` take one query language:

- **Fields:** `from:`, `to:`, `cc:`, `subject:`, `body:` (needs the body index).
- **States and flags:** `has:attachment`, `is:unread|read|flagged|priority`.
- **Scope:** `in:<mailbox>`, `account:<name>`, `category:<name>`.
- **Dates:** `before:`, `after:`, `older:`, `newer:`. Values are ISO dates or relative times like `2h`, `3d` or `yesterday`.
- **Text:** quoted phrases, and `-` to negate any term. Plain words match subject, sender and Mail's summary.

## Safety

- Mutations take exact ids only, and every mutation verb takes `--dry-run`, which prints the resolved targets.
- `send`, `reply --send`, `forward --send` and `unsubscribe --yes` reach other people. Agent-facing help says to draft first.
- One-click unsubscribe (RFC 8058) is an HTTPS POST and runs only with `--yes`.
- No `whose`, enforced by test, as in 0.6.

## Slices

One PR each, stacked in this order. Every PR's verification names a real run of the built binary.

1. Design spec (this document)
2. Read the Envelope Index: `unread`, `search`, `accounts` headless; Exchange; fallback
3. Cache the account map against the system account store
4. Read bodies from disk: headless `read`
5. Act on any message by id: `mark-read`, `archive`, several ids, `--dry-run`
6. `mark-unread`, `flag`, `unflag`, `move`, `delete`
7. Search operators and relative dates
8. Mailbox management
9. `list` and `mailboxes`
10. HTML and Markdown bodies, attachments
11. `open`
12. Mail's on-device categories, summaries and priority
13. `senders`
14. `contacts`
15. `wait` and `watch`
16. `copy` and Gmail labels
17. `junk` and `not-junk`
18. `extract` and `unsubscribe`
19. `reply` and `forward`
20. Body search index
21. Release 0.7.0

## Development rules

- Read-only runs against the real Mail store are fine. Mutating or sending against real mail needs my go-ahead for that run. Until then, prove writes with `--dry-run` output plus unit tests against a fake runner.
- Proof transcripts and PR bodies never contain real subjects, addresses, names or ids. Use counts, timings and redacted lines.
- Index tests use a real SQLite fixture with Mail's column types and indexes, not a hand-shaped result.
