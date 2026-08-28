# mac: your Mac's apps, on the command line

Calendar, Reminders, Contacts, Mail, Messages, Notes, Music, TV, Finder, Keynote, Pages, Numbers and Shortcuts, driven from one binary, plus phone and FaceTime calls. Built for AI agents and the humans who drive them.

    git clone https://github.com/31Carlton7/mac-cli.git && cd mac-cli && make install

Requires macOS 14 or later and Xcode command line tools.

## Native frameworks, not screen scraping

Calendar, Reminders and Contacts run on EventKit and Contacts: millisecond calls, typed errors, stable IDs. Mail, Messages, Notes, Music, TV, Finder, the iWork apps and Shortcuts go through AppleScript and a read-only Messages database, because Apple ships no public API for them, and `mac` is honest about the difference.

## The apps

**Calendar.** Dates take ISO, naturals and offsets.

    mac calendar list --from today --to +7d
    mac calendar add "Dentist" --at "tomorrow 2pm"

**Reminders.** Add, complete and edit across every list.

    mac reminders add "Buy milk" --list Groceries
    mac reminders complete <id>

**Contacts.** Resolve a name to a handle before you send.

    mac contacts find "Sarah"
    mac contacts find "Sarah" --json

**Mail.** Drafting is preferred over sending, by design.

    mac mail unread --limit 10
    mac mail draft --to a@b.com --subject "Hi"

**Messages.** Read history, send texts. Exact handles only.

    mac messages history +15551234567
    mac messages send +15551234567 "On my way"

**Notes.** List, search, add and append by folder.

    mac notes search "brunch"
    mac notes append <id> "one more thing"

**Music.** Playback, search, playlists and star ratings.

    mac music play --playlist Workout
    mac music rate <track-id> 5

**TV.** What's playing, pause, resume, play by id.

    mac tv list --limit 10
    mac tv play <id>

**Finder.** The GUI state your shell cannot reach. No ls or cp, because you already have a shell.

    mac finder selection
    mac finder trash ~/Downloads/old-draft.pdf
    mac finder disks

**iWork.** Agents that ship documents, not descriptions of documents. Text-only edits on open documents, and exports that refuse to overwrite without `--force`.

    mac pages append Letter --text "Sincerely,"
    mac numbers set-cell Q3 --cell B2 --value 42
    mac keynote export Deck --format pdf --out ~/deck.pdf

**Shortcuts.** The escape hatch: anything you can wrap in a Shortcut.

    mac shortcuts list
    mac shortcuts run "Get Weather"

**Calls.** Initiate only. macOS shows its own confirmation before dialing, and there is no answer or hang-up surface.

    mac call "+1 555 123 4567"
    mac facetime user@example.com --audio

## Built for agents, kind to humans

`--json` on every command, with sorted keys, ISO 8601 dates and stable schemas. Mutations take exact IDs only, errors are actionable one-liners on stderr, and exit codes are something an agent can branch on:

| Code | Meaning |
| --- | --- |
| `0` | success |
| `1` | not found or bad input |
| `2` | permission denied |
| `64` | usage error (unknown flag, missing option) |

## Permissions, diagnosed

macOS prompts once per capability, and `mac doctor` reports all fourteen grants (Calendar, Reminders and Contacts access, Automation consent for Mail, Messages, Notes, Music, TV, Shortcuts Events, Finder, Keynote, Pages and Numbers, and Full Disk Access) with fix steps when something is missing. No silent failures, no mystery errors.

    mac doctor

## Some apps cannot be scripted at all

Podcasts, News, Stocks, Maps, Weather, Books, Voice Memos, Freeform, Journal, Home and Passwords expose no automation surface whatsoever, so no tool can drive them directly and `mac` does not pretend otherwise. The [README](https://github.com/31Carlton7/mac-cli#scriptability-of-other-apple-apps) names every one. For those, wrap the job in a Shortcut and run that.

## Next

A Homebrew tap is next, so installing is one command instead of a clone and a build. Photos, QuickTime Player, Preview and TextEdit are all scriptable and are on the list after that.

## About

`mac` is free and MIT licensed, made by [Carlton Aikins](https://carltonaikins.com).
Source: <https://github.com/31Carlton7/mac-cli>
Agent-oriented summary: </llms.txt>
