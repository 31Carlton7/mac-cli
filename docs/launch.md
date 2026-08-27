# Launch kit: mac v0.4.0

Written for the **current release**: ten apps (Calendar, Reminders, Contacts, Mail, Messages, Notes, Music, TV, Shortcuts, plus call and FaceTime initiation), install by cloning and building, macOS 14+, 387 tests.

Site: https://macoscli.sh
Repo: https://github.com/31Carlton7/mac-cli

Keep two caveats intact everywhere: `mac call` and `mac facetime` only initiate, and macOS shows its own confirmation before dialing. And a successful `mac messages send` is not proof of delivery.

---

## Show HN

**Title** (78 chars, fits HN's 80 limit)

    Show HN: Mac, a CLI that gives AI agents access to your macOS apps

**Body**

I kept hitting the same wall with coding agents on my Mac. I could ask one to refactor a service, but I couldn't ask it to put the resulting meeting on my calendar, because there was nothing on the machine for it to call.

So I built `mac`. One binary that drives Calendar, Reminders, Contacts, Mail, Messages, Notes, Music and TV, runs any Shortcut, and can start a phone or FaceTime call.

The part I cared most about is that it behaves when something other than a human is driving. Every command takes `--json` and returns sorted keys and ISO 8601 dates. Exit codes are `0` success, `1` not found or bad input, `2` permission denied, `64` you built the invocation wrong. Mutations only take exact IDs, so an agent has to `list` or `find` before it can `delete`, and it can't invent an identifier and get lucky.

Calendar, Reminders and Contacts run on EventKit and Contacts, so those are native calls with typed errors and stable IDs. Mail, Messages, Notes, Music, TV and Shortcuts go through AppleScript, plus a read-only copy of the chat database for message history, because Apple ships no public API for those. The README says which is which instead of pretending it's uniform.

The thing I ended up proudest of is the part where I gave up. A pile of Apple's own apps have no automation surface at all: Podcasts, News, Stocks, Maps, Weather, Books, Voice Memos, Freeform, Journal, Home, Passwords. I surveyed every first-party app with `sdef` and put the results in the README as a table, including the ones that return error -192 and can never be modules. For those, `mac shortcuts run "Some Shortcut"` is the documented workaround: you wrap the job in a Shortcut once and the agent drives that. I'd rather ship a table that says "impossible, here's the way around it" than quietly fake coverage.

Two things I'd flag as genuinely rough. Mail reads are windowed: each read only examines the newest `--scan` messages per inbox, default 30, because AppleScript's `whose` filtering pinned Mail.app at 98% CPU indefinitely on my 97k-message unified inbox. And a successful `mac messages send` is not proof of delivery, since Messages accepts sends to handles that were never registered with iMessage without erroring. Both are in the README under known limitations.

`mac call` and `mac facetime` only initiate. macOS raises its own confirmation before it dials and there's no answer or hang-up surface, so the CLI doesn't pretend to have one. There's a `--dry-run` that prints the URL it would open.

There's also a `mac doctor` that audits all ten permission grants and prints the fix for whatever is missing, because "operation not permitted" with no other context is a miserable way to find out you needed Full Disk Access.

Requires macOS 14 and Xcode command line tools. MIT licensed. 387 tests. No telemetry, no network calls, no server.

    git clone https://github.com/31Carlton7/mac-cli.git && cd mac-cli && make install

Happy to answer anything about the AppleScript side, that's where most of the pain lived.

---

## X thread

**1/**

Your coding agent can refactor your whole app.

It can't add a thing to your calendar.

So I built `mac`, a CLI that gives it Calendar, Reminders, Contacts, Mail, Messages, Notes, Music, TV and Shortcuts.

Free, MIT, macOS.

https://macoscli.sh

**2/**

The whole design goal was "safe for something else to drive".

→ `--json` on every command, stable schemas
→ exit 0 / 1 / 2 / 64, so you can branch on failure
→ mutations take exact IDs only

No guessing. It has to look something up before it can change it.

**3/**

Calendar, Reminders and Contacts run on EventKit and Contacts. Native calls, millisecond responses, typed errors.

Mail, Messages, Notes, Music, TV and Shortcuts go through AppleScript, because Apple ships no public API for them.

The README tells you which is which. I'd rather be honest than look uniform.

**4/**

Here's the part I'm proudest of, and it's the part where I lost.

Podcasts, News, Stocks, Maps, Weather, Books, Home, Passwords: zero automation surface. Nothing can script them. Not me, not anyone.

I put that in the README as a table instead of quietly faking it.

**5/**

The way around it is one command:

`mac shortcuts run "Log My Weight"`

Wrap the job in a Shortcut once, and your agent can drive anything Shortcuts can reach, including the apps with no API at all.

One escape hatch covers the whole long tail.

**6/**

A war story. My first version used AppleScript's `whose` to filter mail.

On my 97k-message inbox it pinned Mail.app at 98% CPU. Indefinitely.

Now every read is windowed to the newest N messages. It's a real limitation and it's documented as one.

**7/**

Ten apps, 387 tests, MIT.

    git clone https://github.com/31Carlton7/mac-cli.git && cd mac-cli && make install

Finder is next, then Keynote/Pages/Numbers.

macOS 14+. Would love to know what you'd want it to reach next.

---

## Reddit

Best fits: r/macapps, r/commandline, r/ClaudeAI. Post to one, wait a day, then the next. Do not cross-post the same text the same hour.

**Title**

    I built a CLI that gives AI agents access to Calendar, Mail, Messages, Notes, Music and more on macOS (free, MIT)

**Body**

I use coding agents on my Mac all day, and the gap kept bugging me: they can touch every file in my project but nothing in the apps I actually live in. There's no public surface for "put this on my calendar."

`mac` is one binary that covers Calendar, Reminders, Contacts, Mail, Messages, Notes, Music and TV, runs any Shortcut, and can start a phone or FaceTime call.

It's built so something other than a human can run it safely:

- `--json` on every command, with sorted keys and ISO 8601 dates
- exit codes you can branch on: 0 success, 1 not found, 2 permission denied, 64 bad invocation
- mutations take exact IDs only, so an agent has to look a thing up before it can delete it
- `mac doctor` audits all ten permission grants and tells you how to fix the missing one

Calendar, Reminders and Contacts use the native frameworks. Mail, Messages, Notes, Music, TV and Shortcuts use AppleScript, since Apple gives you nothing else.

The bit I think is actually useful: I surveyed every first-party Apple app to see what can be scripted at all, and the README has the table. Podcasts, News, Stocks, Maps, Weather and a bunch of others have no automation surface whatsoever, so nothing can drive them. For those, you wrap the task in a Shortcut and run `mac shortcuts run "Your Shortcut"`. I'd rather document the dead ends than pretend they don't exist.

Calls only initiate, and macOS confirms before dialing.

Nothing leaves your machine. No telemetry, no account, no server.

macOS 14+, MIT licensed: https://macoscli.sh

Curious which app people would want covered next.

---

## Short forms

**One-liner**

    Your Mac's apps, on the command line. Ten apps, --json on everything, exit codes an agent can branch on.

**GitHub repo description** (already applied)

    An agent-friendly CLI for native macOS apps. Calendar, Reminders, Contacts, Mail, Messages and Notes from one binary, with --json on every command, stable exit codes and IDs you can trust. MIT.

Worth refreshing for 0.4.0:

    An agent-friendly CLI for native macOS apps. Calendar, Reminders, Contacts, Mail, Messages, Notes, Music, TV, Shortcuts and calls from one binary, with --json on every command, stable exit codes and IDs you can trust. MIT.

**GitHub topics** (already set)

    macos, cli, swift, applescript, eventkit, ai-agents, claude-code, automation, imessage

---

## Checklist

Before posting:

- [x] DNS for macoscli.sh points at Vercel, https://macoscli.sh loads
- [x] Repo description and topics set, website field set to https://macoscli.sh
- [x] README links to the site
- [ ] Refresh the repo description for 0.4.0 (text above)
- [ ] Card preview renders (test at opengraph.xyz or by pasting the link into a DM)
- [ ] `git clone ... && make install` verified from scratch in a clean directory
- [ ] Tagged release v0.4.0 on GitHub so people can cite a version

Timing: Show HN lands best Tuesday to Thursday, roughly 9-11am ET. Post it yourself, don't ask anyone to upvote, and stay in the thread for the first two hours since early replies decide it.

If it does well, expect three questions. "Why not just MCP" (this is the layer under it, any agent that can run a shell command gets it, and you can pipe it). "Is this safe" (local only, no network, mutations need exact IDs, drafting preferred over sending, calls only initiate and macOS confirms). And "why can't it do Podcasts" (it can't, nothing can, and the README table says so; use a Shortcut).
