# mac

**[macoscli.sh](https://macoscli.sh)**

An agent-friendly CLI for native macOS apps. Calendar, Reminders, and Contacts run on native frameworks (EventKit, Contacts) for millisecond calls with typed errors and stable IDs; Mail, Messages, Notes, Music, TV, Shortcuts, Finder, and the iWork apps (Keynote, Pages, Numbers) use AppleScript (and read-only Mail and Messages databases), since Apple ships no public APIs for them.

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

Mail, Messages, Notes, Music, TV, Shortcuts, Finder, Keynote, Pages, and Numbers additionally need Automation consent (prompted on first use) and, for reading Messages history and Mail's Envelope Index, Full Disk Access for your terminal app — `mac doctor` reports all of it with fix steps.

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
mac mail search "from:github.com is:unread newer:2d"
mac mail index build
mac mail search 'body:"tracking number" newer:30d'
mac mail index status
mac mail list --mailbox Sent --limit 5
mac mail mailboxes --account Work
mac mail read <id>
mac mail archive <id> <id> --dry-run
mac mail flag <id>
mac mail move <id> --to Projects --dry-run
mac mail open abc123@example.com
mac mail senders --by domain --unread --limit 10
mac mail contacts ann
mac mail wait 'from:github.com subject:"verification code"' --timeout 2m --json
mac mail watch 'is:unread -category:promotions' --json
mac mail label add <id> Receipts --dry-run
mac mail junk <id> --dry-run
mac mail extract <id> --codes --json
mac mail unsubscribe <id>
mac mail draft --to a@b.com --subject "Hi" --body "..."
mac mail draft --to a@b.com --subject "Notes" --markdown-file notes.md --attach report.pdf
mac mail reply <id> --all --body "Thanks, see you then." --dry-run
mac mail forward <id> --to a@b.com --body "FYI"
mac mail mailboxes create 2026 --parent Projects --account Work --dry-run
mac mail mailboxes delete Projects/2026 --account Work
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
mac keynote new --theme White --out ~/Desktop/pitch.key
mac keynote add-slide pitch.key --title "Roadmap" --body "Q3 milestones"
mac pages new --out ~/Desktop/letter.pages
mac pages set-body letter.pages --text "Dear Sam,"
mac numbers set-cell budget.numbers --cell B2 --value 42
mac keynote export pitch.key --format pdf --out ~/Desktop/pitch.pdf --force
```

Every command supports `--json`. Dates accept ISO (`2026-08-27 14:00`), naturals (`tomorrow 2pm`, `friday`), and offsets (`+7d`, `+2h`).

## For agents

- `--json` on every command; sorted keys, ISO 8601 dates; schemas are stable.
- Exit codes: `0` success, `1` not found / bad input, `2` permission denied.
- Mutations (`edit`, `delete`, `complete`, and every `mac mail` change) take exact IDs only — get IDs from `list`/`find`/`unread`/`search`.
- Discovery commands: `mac calendar calendars` and `mac reminders lists` return objects (`{id,title,kind}`); `mac mail accounts` returns a plain string array, since a Mail account's name is its identifier.
- Errors are actionable one-liners on stderr; `mac doctor` reports missing permissions with fix steps.
- Malformed invocations (unknown flags, missing required options) exit `64` (BSD EX_USAGE); `1` is reserved for semantic errors — not found or bad input.
- `--json` always prints, even with `--quiet`; `--quiet` suppresses human-readable output only.
- `mac mail mailboxes` lists each mailbox with its `account`, `path`, `total` and `unread` counts; `path` is what `mac mail list --mailbox` and `in:` accept. It leaves out empty system mailboxes (Exchange's Journal, Gmail's Starred, an empty Trash) unless `--all`, and always lists empty mailboxes you made. `mac mail list` is the newest messages of one mailbox, by default every enabled account's inbox, narrowed by the `search` operators; `--unread` and `--flagged` are `is:unread` and `is:flagged`. A `--mailbox` that names nothing in scope is not found, never an empty list.
- `mac mail wait QUERY` blocks until a matching message arrives, prints it and exits `0`; after `--timeout` (default `2m`) it exits `1` with `notFound`. `--since 10m` also accepts a match already received in that time, for mail that landed before the wait began. `mac mail watch [QUERY]` prints each new match once, one JSON object per line with `--json`, until Ctrl-C or SIGTERM (exit `0`) or `--count N`. Both look in every enabled account's inbox unless `--mailbox` or `in:` names another, take the `search` operators, and check every `--interval` (`2s` for `wait`, `5s` for `watch`). Relative dates in QUERY, like `newer:2h`, are fixed when the command starts.
- `mac mail search 'body:WORD'` (or `body:"a phrase"`, or `body:invo*` for a prefix) matches message bodies through a local index that `mac mail index build` creates and updates; `search --body` makes plain words match bodies too. `list`, `wait` and `watch` take `body:` as well, and `wait`/`watch` index each new message as it arrives. Body matches are whole words, ignoring case and accents, unlike the substring match on subject and sender. When the index has not caught up, `search` and `list` still answer and print one stderr note with how many messages they could not check. `mac mail index status` reports `indexed`, `behind`, each account's `watermark`, Mail's `newestRowID`, `fileSize` and `lastBuild`, counts only; `mac mail index clear` deletes the file.
- `mac mail mailboxes create|rename|delete` address a mailbox by path within one `--account` (`Projects/2026`) and take `--dry-run`, which resolves the account and mailbox and prints the planned change without making it. `delete` refuses system mailboxes (Inbox, Sent, Drafts, Trash, Junk, Archive, All Mail and their provider and localized names), mailboxes that still hold messages, and mailboxes with children; `rename` refuses system mailboxes too.
- `mac mail mark-read`, `mark-unread`, `flag`, `unflag`, `archive`, `move --to`, `copy --to`, `label add`, `delete`, `junk` and `not-junk` take several ids and `--dry-run`, which prints the resolved messages without changing anything. They print `{"results":[{"id","account","mailbox","status","verified"}]}` (`status` is `ok`, `notFound`, `failed` or `dryRun`; `verified` means Mail's index showed the change) and exit 1 if any id was not changed. A message with copies in several mailboxes is refused until `--mailbox` or `--account` picks one.
- Mail message ids are the RFC Message-ID without angle brackets. Items read from Mail's Envelope Index also carry `mailbox`, `to`, `cc`, `isFlagged`, `hasAttachments` and `isPriority`, plus Mail's on-device `category` (`primary`, `transactions`, `updates` or `promotions`) and its Apple Intelligence `summary` when Mail has made them, and `mac mail read` adds `attachments` (`name`, `mimeType`, `size`, `isExternal`) when it decoded the message file; a key appears only when its value is known. Human output tags non-primary categories and priority (`[updates]`, `[priority]`) and leaves the summary to `--json`.
- `mac mail senders` ranks who sends the most mail to your inboxes, per address or `--by domain`, with each sender's most used name, `count`, `unreadCount` and `latest` date. It takes the same query as `search` to narrow the count (`in:` counts that mailbox instead); follow up on one sender with `mac mail search 'from:<domain>'`.
- `mac mail contacts QUERY` finds addresses you have exchanged mail with whose address or name contains QUERY: people who sent you mail, and To/Cc recipients of mail in your Sent mailboxes. Each has its most used `name`, `messageCount` and `lastContact`, most messages first. It reads Mail, not your address book; that is `mac contacts find`.
- Prefer `mac mail draft` over `mac mail send`, and `reply`/`forward` without `--send`, unless the user explicitly asked to send.
- `mac mail extract <id>` prints `{"codes":[{"code","confidence","context"}],"links":[{"url","text","isUnsubscribe"}],"unsubscribe":{"mailto":[...],"https":[...],"oneClick":bool}}`; `--codes`, `--links` and `--unsubscribe` pick parts, and a part not asked for is left out. `confidence` is `high`, `medium` or `low`, best first.
- `mac mail unsubscribe <id>` is a dry run that prints the plan and exits 0. Run it without `--yes` first and show the plan. `--yes` acts: an RFC 8058 one-click POST when the sender offers it, otherwise a draft of the `mailto:` unsubscribe email (`--send` sends it). It prints `{"id","method","target","email","send","status","httpStatus","detail"}` and exits 1 when it did not unsubscribe, or when the message offers no way to.
- `mac mail draft`/`send`/`reply`/`forward` take one body: `--body`, `--html` or `--markdown`, or a `-file` variant of each. `--attach` repeats. `--dry-run` prints what would be composed without opening Mail; attachments are checked before Mail is touched.
- `mac mail reply <id> [--all]` and `mac mail forward <id> --to <addr>[,…] [--cc …]` have Mail.app reply to or forward the exact message the id resolves to, so Mail sets the recipients, the `Re:`/`Fwd:` subject, In-Reply-To, References and the quote. They leave a draft open unless `--send`. They print `{"action","status","id","account","mailbox","subject","to","cc","quote","attachments"}`, with `status` `draft`, `sent` or `dryRun`. `to`, `cc` and `subject` are read back from Mail's outgoing message; on a dry run they are what Mail is expected to make. `--send` sends only when Mail's message has its recipients (and, for a forward, every address given), and otherwise leaves it open as a draft and exits 1. Ids resolve like the by-id actions.
- `mac messages send` takes exact handles only — resolve names with `mac contacts find` first.
- `mac call`/`mac facetime` are initiate-only; macOS confirms before dialing.
- `mac shortcuts run` is the escape hatch for unscriptable apps: wrap the task in a Shortcut and run it by name or id.
- `mac finder trash` is the recoverable delete: the item goes to the Trash, same as dragging it there in Finder, and can be restored until the Trash is emptied — prefer it over `rm` for user files.
- iWork exports (`mac keynote/pages/numbers export`) never overwrite an existing file — they fail with a clear error unless you pass `--force`.

## Known limitations

- **Recurring events** share one ID across all occurrences; `edit`/`delete` act on the series master, not a specific occurrence.
- **Date-only due dates** get a time of midnight — every reminder due date carries a time.
- **Duplicate calendar/list names** (e.g. "Personal" in two accounts) resolve to the first match.
- Contact phone/email labels (mobile/work/home) are flattened to plain values.
- **No clear-to-nil:** edit flags replace values. A due date, once set, cannot be removed; notes/location/org can be blanked by passing an empty string. Names and titles cannot be set to empty.
- **`mac mail unread`, `search`, `list` and `mailboxes` read Mail's Envelope Index** (`~/Library/Mail/V*/MailData/Envelope Index`), which needs Full Disk Access. They see every message Mail has downloaded, in every account including Exchange. `unread` is the newest `--limit` unread inbox messages across all enabled accounts. `search` matches every plain word against subject, sender, and Mail's summary in every mailbox except Trash and Junk, and lists a message copied into several mailboxes once. It also takes operators: `from:`, `to:`, `cc:`, `subject:`, `has:attachment`, `is:unread|read|flagged|priority`, `in:`, `account:`, `category:`, and `after:`/`before:`/`newer:`/`older:` with dates like `2026-10-01`, `yesterday` or `3d`; prefix any term with `-` to exclude it (`mac mail search --help` lists them all). Naming a mailbox with `in:` searches it even when it is Trash or Junk; `in:sent`, `in:trash` and `in:junk` (or `in:spam`) also match each provider's own name, such as Gmail's `[Gmail]/Sent Mail` or Exchange's `Sent Items` and `Deleted Items`. A Gmail message has one row, in All Mail, so `list --mailbox` on a Gmail label reports `mailbox` as `[Gmail]/All Mail` (or `Inbox` when it is also in the inbox). Matching is case-insensitive for ASCII letters only. `--scan` is ignored on this path.
- **A message without a Message-ID header is listed with an empty `id`** (`(no Message-ID)` in human output). mac does not invent one, so such a message cannot be read or acted on by id.
- **Mail's account list is cached** in `~/Library/Caches/mac-cli/mail-accounts.json`, keyed to a fingerprint of each account's id, name, parent and Mail switch in the system account store (`~/Library/Accounts/Accounts4.sqlite`), so a read with a warm cache makes no Mail.app call, and routine writes to that store, such as token refreshes, leave the cache in place. Adding, removing, renaming or toggling an account changes the store, and the next read asks Mail.app again. An `--account` name the cache does not know is checked with Mail.app before it is reported missing. Without Full Disk Access to the account store, every read asks Mail.app, as before. `--no-cache` on `unread`, `search`, `list`, `mailboxes`, `read`, `accounts`, `index`, `senders`, `contacts`, `wait` and `watch` skips the cache. Commands that change or compose mail always ask Mail.app; `extract` and a dry-run `unsubscribe` never do.
- **`mac mail read` decodes the message file** (`.emlx` under `~/Library/Mail/V*`) for a message in any mailbox of any account, so it reaches mail no inbox window would. A message copied into several mailboxes is read from its inbox copy, then the newest. The body is the text/plain part when there is one, otherwise readable text from the HTML with link URLs kept, so it is often longer than what Mail.app shows. When the file is missing or does not decode, `read` asks Mail.app for that one message by its numeric id, with a warning. An id the index does not have is `notFound`.
- **`mac mail` mutations find each id in the index, then have Mail.app change exactly that message by its numeric id**, one script per account and no window. An id missing from the index fails the whole call before anything changes. After acting they wait up to 2 seconds for the index to show the change, and report `verified: false` rather than wait longer.
- **`mac mail archive` refuses Gmail.** Gmail archives by removing the Inbox label, and Mail keeps a Gmail message once, in All Mail, so a scripted move to All Mail moves the message onto itself and can leave the label on the server. Only Mail's own Archive command does it reliably, and that needs Mail's windows. Exchange, iCloud and other IMAP accounts move to their `Archive` mailbox; an account without one is `notFound`. `move` refuses Gmail too, since a Gmail mailbox is a label and a move would have to remove one.
- **`mac mail copy` keeps the original where it is.** It uses Mail's `duplicate` into a mailbox of the message's own account, and refuses Trash, Junk, and a mailbox that already holds the message. On Gmail a copy into a label's mailbox is how Mail adds the label, so it is verified by a new label row; `mac mail label add <id>... <label>` does the same and refuses non-Gmail accounts. The label must already exist.
- **`mac mail junk` marks and files; `not-junk` unmarks and returns.** `junk` sets Mail's junk mark (`junk mail status`, which also trains Mail's junk filter) and moves the message to its account's one Junk mailbox (`Junk Email` on Exchange, `[Gmail]/Spam` on Gmail). A message already there only gets the mark, and one that has both is refused. `not-junk` clears the mark and moves a message in Junk to the account's inbox; elsewhere it only clears the mark. A move is verified by the index; a mark-only change by the junk bit of the row's `flags`. Gmail's own Spam filing usually leaves Mail's mark unset.
- **`mac mail label remove` always refuses.** Mail's scripting has no label command. Removing a label means a scripted move out of its mailbox, which can leave the label on the server (the same problem as Gmail archive), or Mail's Delete there, which moves the message to Trash. Remove labels in Mail.
- **`mac mail delete` never erases.** It uses Mail's own Delete, which moves the message to its account's Trash (`Deleted Items` on Exchange, `[Gmail]/Trash` on Gmail). It refuses an account that Mail is set to erase deleted messages from, a message already in Trash, and an account with no Trash or more than one.
- **Most of `mac mail` needs Mail's Envelope Index**: `mark-unread`, `flag`, `unflag`, `move`, `delete`, `copy`, `label add`, `junk`, `not-junk`, `reply`, `forward`, `extract`, `unsubscribe`, `senders`, `contacts`, `wait` and `watch` exit 2 naming Full Disk Access without it. `draft`, `send`, `open` and `accounts` do not use it.
- **Without the index, Mail reads are windowed.** When the index is unreadable, `unread`, `search`, `read`, `mark-read`, `archive` and an inbox `list` with plain words or `--unread` fall back to Mail.app with a warning (any other `list`, and `mailboxes`, is permission denied naming `mac doctor`), and each examines only the newest `--scan` messages (default 30) of each account's inbox. A message older than that window is invisible — raise `--scan` (max 500) to look further back. In this mode `unread` without `--account` is a fast sample, not a global newest-N, and search matches plain words against subject/sender only; operators need the index. AppleScript's `whose` filtering, which would search the whole mailbox, is unusable: on a 97k-message unified inbox it pins Mail.app at 98% CPU indefinitely.
- **In that fallback, reads on large mailboxes are slow.** Cost scales with messages touched: roughly 0.15s/message on a 1.7k-message account and ~1.5s/message on a 50k-message one. Keep `--scan` small on big accounts.
- **`wait` and `watch` notice mail through the Envelope Index**, so Mail must be running and fetching. A message counts as new when Mail stores it after the command starts, whatever date its sender wrote; a message Mail stores again under a new row, as a move between mailboxes can, counts as new too, but one Message-ID is printed only once per run. A Gmail message whose inbox label lands more than 30 seconds after the message itself is missed by an inbox-scoped wait. Mail.app is asked once for the account list at the start, then only the index is read; if the index stops being readable, the command exits `2`.
- **Body search reads mac's own index, not Mail's.** Mail's Spotlight data is private, so `mac mail index build` decodes every message file of every enabled account (or `--account`) and stores a full-text index in `~/Library/Caches/mac-cli/mail-bodies.sqlite`, mode 0600 in a 0700 directory. **That file holds private mail content** (the words of every message, not the messages themselves); nothing else is written anywhere, and Mail's own files are only read. Delete it with `mac mail index clear`. The first build reads the whole store (79 seconds for 107k messages here, giving a 107 MB file); later builds read only messages Mail stored since the last one, retry files Mail had not downloaded, and drop messages Mail deleted. When Mail rebuilds its own index and numbers its messages afresh, the next build starts over. Ctrl-C keeps what is done, and the next build resumes. Nothing updates the index in the background: `body:` sees mail up to the last build, plus what a running `wait` or `watch` indexed, and says how many messages it missed. A `wait` or `watch` with `body:` keeps checking a new message its query could pick until Mail has written its file, for up to 90 seconds; after that it moves on without that message's body and prints one stderr note. A changed message keeps the words it had when it was indexed. Each body is indexed up to 256 KB of text, and a web link only by its host (`body:github.com` matches a link to GitHub; a word in a link's path does not). Attachments, subjects and headers are not part of the body index, and a message whose text Mail stored outside its message file (10 of 107k here) is not indexed. A query that starts with `-` goes after `--`: `mac mail search --json -- '-body:invoice'`.
- **`mac mail senders` and `contacts` have no Mail.app fallback**, since Mail.app cannot count a whole mailbox by sender. A Gmail message with several labels, or a message copied into several mailboxes, counts once.
- **`mac mail contacts` finds sent mail by mailbox name**: `Sent`, `Sent Items`, `Sent Messages` and `[Gmail]/Sent Mail`. A localized or custom sent mailbox is not searched for recipients. Bcc recipients and mail received in Trash or Junk do not count, and you are left out as the sender of your own sent mail.
- **Mail's categories and summaries come from Mail itself.** They exist only where Mail's on-device categorisation and Apple Intelligence have run; Mail summarises only some messages, and a Mac without them returns neither key.
- **`mac mail extract` finds codes by heuristics.** A code is a 4 to 8 character token of digits, or capital letters with a digit, near a word like "verification code", "passcode" or "one-time" (with a few Spanish, French, German, Italian, Chinese, Japanese and Korean equivalents). Years, prices, phone numbers, promo codes and numbers labelled as orders, accounts or confirmation numbers are skipped, but a cued number that is not a one-time code can still come back: a standing meeting passcode comes back at lower confidence when the message reads as a meeting invitation, and at high confidence when it does not. Links unwrap only Google, Outlook Safe Links, Facebook, Instagram, LinkedIn, YouTube, Slack, VK and Steam redirects; other click trackers are left as they are, since their own URL may be what records an unsubscribe. A link counts as an unsubscribe link only when its text or URL says unsubscribe (or opt out); "manage preferences" links do not. `extract` reads the message file and never asks Mail.app, so a message whose file Mail has not downloaded is not found.
- **`mac mail unsubscribe` never fetches a link.** One-click is one HTTPS POST with a 10 second timeout, no cookies, and no redirects followed (a 3xx is a failure, as RFC 8058 has senders answer directly). A sender that offers only a web page, through `List-Unsubscribe` without one-click or a link in the body, gets that link printed for you to open; a GET can be a tracking or confirmation page. Plain `http:` List-Unsubscribe targets are ignored. A `mailto:` draft uses the first address and comes from Mail's default account, not necessarily the one that received the message; review the draft's From before sending.
- **Mailbox system names are matched by name.** `mac mail mailboxes delete`/`rename` recognise system mailboxes from a fixed list of English, German, French and Spanish names and Gmail's `[Gmail]/` folders; a provider that names its system folders differently is not protected by that check (the empty-mailbox check still applies to delete).
- **HTML mail's plain-text part is Mail's own.** `--html` and `--markdown` set Mail's undocumented `html content` property, the one scripted route to an HTML body that worked in testing. Mail wraps the HTML in a quote block, so the plain-text alternative it generates at send time prefixes every line with `> `, and a saved draft's plain-text part stays empty until it is sent.
- Markdown covers headings, paragraphs, one level of lists, quotes, fenced code, rules, inline code, emphasis, and http/https/mailto links. Raw HTML in Markdown is shown as text.
- **A reply or forward with a body or `--attach` has a quote rebuilt by mac.** Mail drops its own quote, and a forward's attachments, as soon as a script touches the body, including to attach a file. So when you add content, mac writes the new text first and quotes the original below it in Mail's style (an "On …, … wrote:" line, or a "Begin forwarded message:" header block), from the text `mac mail read` would show: the original's formatting and inline images are not kept, and the attribution is in English. A forward carries the original's attachments as files; one Mail has not downloaded makes `forward` fail before Mail is asked. Without a body or `--attach`, Mail's own reply or forward is left untouched.
- **`mac mail open` does not look the message up.** It hands Mail a `message:` URL built from the id, so it works on any message Mail has, but an `opened` confirmation is not proof the id exists: Mail opens no window and shows no error for an unknown one.
- Messages: group chats are read-only.
- `mac messages history` accepts an exact handle or, failing that, an unambiguous 10+ digit variant; a variant matching more than one conversation is rejected rather than guessed.
- `mac messages send` requires an exact handle — it does no normalization.
- **A successful `mac messages send` is not proof of delivery.** Messages accepts sends to handles that were never registered with iMessage (typos, SMS-only contacts) without a synchronous error. Verify by reading the thread back with `mac messages history`.
- Notes: password-protected notes appear in listings but their bodies read as empty; `delete` moves to Recently Deleted (recoverable) rather than erasing; folder names are resolved per-name, so duplicates across accounts need `--account`; checklists and attachments flatten to plain text.
- **`mac music search`/`mac music playlists` see your library, not the Apple Music catalog.** Songs you haven't added won't turn up in search, and Apple Music's `whose`-based library search is unusable at scale (the same measured cost that ruled out `whose` for Mail) — `mac music` and `mac tv` resolve a track/playlist by id via the one sanctioned `whose persistent ID is "<id>"` lookup, run under a 30s timeout, since that shape stayed fast in measurement.
- `mac shortcuts run` blocks until the shortcut finishes; a shortcut that shows its own dialogs or waits on user input will hang the command until that shortcut completes.
- `mac call`/`mac facetime` only open a `tel:`/`facetime:` URL — they never place the call themselves; macOS still asks you to confirm before dialing.
- **iWork commands operate on OPEN documents.** `mac keynote/pages/numbers` verbs address documents that are currently open in the app, by NAME (as listed by `docs`) — there is no open-by-path; `new` creates (and opens) a document, optionally saving it with `--out`. Saved documents are named with their file extension (`deck.key`), but the extension may be omitted when unambiguous (`mac keynote slides deck`). Two open documents matching a name are rejected as ambiguous rather than guessed.
- **iWork edits are text-only and coarse.** Pages editing is the whole body text (`get-body`/`set-body`/`append`) — no styling, images, or per-paragraph addressing; Keynote `add-slide` sets the default title/body items only; Numbers addresses one cell at a time by A1 ref inside **1-based** `--sheet`/`--table` indexes.
- `mac keynote add-slide` may create the slide and then refuse the title: on a layout without a title item, the slide exists but setting its title text fails — check `mac keynote slides` before retrying.
- **`mac numbers get-cell` reads values back as text**, and Numbers hands numerics back in its own formatting — a cell set to `42` typically reads back as `42.0`.
- **`mac finder` is trash-only, by design.** It moves files to the Trash (recoverable); it does not copy, move, rename, or permanently delete. It reflects and drives Finder's GUI state (selection, reveal, open, disks, eject) — for bulk or scripted file operations, use your shell.

## Scriptability of other Apple apps

A survey of remaining first-party apps not yet covered by `mac`, for anyone weighing whether to script them directly or via `mac shortcuts run`. (Finder shipped in v5, Keynote/Pages/Numbers in v6 — see Usage above.)

| App | Status | Notes |
| --- | --- | --- |
| Photos | Scriptable, not yet wired up | Has a real AppleScript dictionary; candidate for a future module. |
| QuickTime Player | Scriptable, not yet wired up | Recording/playback are scriptable. |
| Preview | Scriptable, not yet wired up | Limited but real dictionary (open/print/close). |
| TextEdit | Scriptable, not yet wired up | Full document AppleScript support. |
| Keynote / Pages / Numbers | **Shipped in v6** | `mac keynote` / `mac pages` / `mac numbers` — see Usage above. |
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

Homebrew tap.

## License

MIT
