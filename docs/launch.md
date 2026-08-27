# Launch kit: mac v0.3.0

Everything below is written for the **current release**: six apps (Calendar, Reminders, Contacts, Mail, Messages, Notes), install by cloning and building, macOS 14+. Music, TV, Shortcuts and calls are v0.4.0 and are not mentioned as available anywhere in here.

Site: https://macoscli.sh
Repo: https://github.com/31Carlton7/mac-cli

---

## Show HN

**Title** (76 chars, fits HN's 80 limit)

    Show HN: Mac, a CLI for Calendar, Reminders, Contacts, Mail, Messages, Notes

**Body**

I kept running into the same wall with coding agents on my Mac. I could ask one to refactor a service, but I couldn't ask it to put the meeting on my calendar, because there was nothing on the machine for it to call.

So I built `mac`. One binary that drives Calendar, Reminders, Contacts, Mail, Messages and Notes from the command line.

The part I cared most about is that it behaves itself when something else is driving it. Every command takes `--json` and returns sorted keys and ISO 8601 dates. Exit codes are `0` success, `1` not found or bad input, `2` permission denied, `64` you built the invocation wrong. Mutations only take exact IDs, so an agent has to `list` or `find` before it can `delete`, and it can't invent an identifier and get lucky.

Calendar, Reminders and Contacts run on EventKit and Contacts, so those are native calls with typed errors and stable IDs. Mail, Messages and Notes go through AppleScript, plus a read-only copy of the chat database for message history, because Apple ships no public API for those three. The README says which is which instead of pretending it's uniform.

Two things I'd flag as genuinely rough. Mail reads are windowed: each read only examines the newest `--scan` messages per inbox, default 30, because AppleScript's `whose` filtering pinned Mail.app at 98% CPU indefinitely on my 97k-message unified inbox. And a successful `mac messages send` is not proof of delivery, since Messages accepts sends to handles that were never registered with iMessage without erroring. Both are in the README under known limitations.

There's a `mac doctor` that audits every permission and prints the fix step for whatever is missing, because "operation not permitted" with no other context is a miserable way to find out you needed Full Disk Access.

Requires macOS 14 and Xcode command line tools. MIT licensed. No telemetry, no network calls, no server.

    git clone https://github.com/31Carlton7/mac-cli.git && cd mac-cli && make install

Happy to answer anything about the AppleScript side, that's where most of the pain lived.

---

## X thread

**1/**

Your coding agent can refactor your whole app.

It can't add a thing to your calendar.

So I built `mac`, a CLI that gives it Calendar, Reminders, Contacts, Mail, Messages and Notes.

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

Mail, Messages and Notes go through AppleScript, because Apple ships no public API for them.

The README tells you which is which. I'd rather be honest than look uniform.

**4/**

The bit I'm most glad I built:

`mac doctor`

It checks every permission the tool needs and prints the exact fix for whatever is missing.

"Operation not permitted" with no explanation is a terrible way to learn you needed Full Disk Access.

**5/**

A war story. My first version used AppleScript's `whose` to filter mail.

On my 97k-message inbox it pinned Mail.app at 98% CPU. Indefinitely.

Now every read is windowed to the newest N messages. It's a real limitation and it's documented as one.

**6/**

Six apps today. Music, TV, Shortcuts and calls are next.

    git clone https://github.com/31Carlton7/mac-cli.git && cd mac-cli && make install

macOS 14+. Would love to know what you'd want it to reach next.

---

## Reddit

Best fits: r/macapps, r/commandline, r/ClaudeAI. Post to one, wait a day, then the next. Do not cross-post the same text the same hour.

**Title**

    I built a CLI that gives AI agents access to Calendar, Reminders, Contacts, Mail, Messages and Notes on macOS (free, MIT)

**Body**

I use coding agents on my Mac all day, and the gap kept bugging me: they can touch every file in my project but nothing in the apps I actually live in. There's no public surface for "put this on my calendar."

`mac` is one binary that covers Calendar, Reminders, Contacts, Mail, Messages and Notes.

It's built so something other than a human can run it safely:

- `--json` on every command, with sorted keys and ISO 8601 dates
- exit codes you can branch on: 0 success, 1 not found, 2 permission denied, 64 bad invocation
- mutations take exact IDs only, so an agent has to look a thing up before it can delete it
- `mac doctor` audits every permission and tells you how to fix the missing one

Calendar, Reminders and Contacts use the native frameworks. Mail, Messages and Notes use AppleScript, since Apple gives you nothing else. The README is upfront about the difference, and about the real limitations (mail reads are windowed, group chats are read-only, recurring events share one ID).

Nothing leaves your machine. No telemetry, no account, no server.

macOS 14+, MIT licensed: https://macoscli.sh

Curious which app people would want covered next.

---

## Short forms

**One-liner**

    Your Mac's apps, on the command line. Calendar, Reminders, Contacts, Mail, Messages and Notes, with --json on everything.

**GitHub repo description** (under 350 chars)

    An agent-friendly CLI for native macOS apps. Calendar, Reminders, Contacts, Mail, Messages and Notes from one binary, with --json on every command, stable exit codes and IDs you can trust. MIT.

**GitHub topics**

    macos, cli, swift, applescript, eventkit, ai-agents, claude, automation, command-line

---

## Checklist

Before posting:

- [ ] DNS for macoscli.sh points at Vercel, https://macoscli.sh loads
- [ ] Card preview renders (test at opengraph.xyz or by pasting the link into a DM)
- [ ] Repo description and topics set, website field set to https://macoscli.sh
- [ ] README links to the site
- [ ] `git clone ... && make install` verified from scratch in a clean directory
- [ ] Tagged release v0.3.0 on GitHub so people can cite a version

Timing: Show HN lands best Tuesday to Thursday, roughly 9-11am ET. Post it yourself, don't ask anyone to upvote, and stay in the thread for the first two hours since early replies decide it.

If it does well, expect two questions: "why not just MCP" (answer: this is the layer under it, any agent that can run a shell command gets it, and you can pipe it) and "is this safe" (answer: local only, no network, mutations need exact IDs, and drafting is preferred over sending in Mail).
