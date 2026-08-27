# mac: your Mac's apps, on the command line

Calendar, Reminders, Contacts, Mail, Messages and Notes, driven from one binary. Built for AI agents and the humans who drive them: every command has `--json`, stable exit codes, and IDs you can trust.

    git clone https://github.com/31Carlton7/mac-cli.git && cd mac-cli && make install

Requires macOS 14 or later and Xcode command line tools.

## Native frameworks, not screen scraping

Calendar, Reminders and Contacts run on EventKit and Contacts: millisecond calls, typed errors, stable IDs. Mail, Messages and Notes go through AppleScript and a read-only Messages database, because Apple ships no public API for them, and `mac` is honest about the difference.

## The six apps

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

## Built for agents, kind to humans

`--json` on every command, with sorted keys, ISO 8601 dates and stable schemas. Mutations take exact IDs only, errors are actionable one-liners on stderr, and exit codes are something an agent can branch on:

| Code | Meaning |
| --- | --- |
| `0` | success |
| `1` | not found or bad input |
| `2` | permission denied |
| `64` | usage error (unknown flag, missing option) |

## Permissions, diagnosed

macOS prompts once per capability, and `mac doctor` reports every grant (Calendar, Reminders and Contacts access, Automation consent, Full Disk Access) with fix steps when something is missing. No silent failures, no mystery errors.

    mac doctor

## Next

Music, TV, Shortcuts and call initiation are in development for v0.4.0 and are not in the current release. Shortcuts is the escape hatch: wrap an app that has no scripting surface of its own in a Shortcut, and agents can drive it too.

## About

`mac` is free and MIT licensed, made by [Carlton Aikins](https://carltonaikins.com).
Source: <https://github.com/31Carlton7/mac-cli>
Agent-oriented summary: </llms.txt>
