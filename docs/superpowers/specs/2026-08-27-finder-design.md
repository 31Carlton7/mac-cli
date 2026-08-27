# mac-cli v5 Design — Finder

**Date:** 2026-08-27
**Status:** Approved (single-pass build)
**Builds on:** v1–v4 (all shipped; v4 gotcha ledger applies)

## Purpose

`mac finder` — the GUI-state module. Agents already have shells, so this module deliberately does NOT duplicate ls/cp/mv/mkdir. It covers only what a shell cannot reach: the user's current Finder selection, revealing/opening things in the GUI, Trash-safe deletion, and volume management. Finder's dictionary: 25 commands/32 classes (surveyed).

## Command surface

```
mac finder selection            # what the user has selected, as items (path, name, kind)
mac finder reveal <path>        # reveal + select in a Finder window (activates Finder)
mac finder open <path>          # open with the default app (like double-click)
mac finder trash <path>         # move to Trash — recoverable, the only mutation
mac finder disks                # mounted volumes (name, capacity/free in bytes, ejectable)
mac finder eject <name>         # eject a removable volume by exact name
```

- **Non-goals:** empty-trash (permanently destructive — excluded on principle), file copy/move/rename/mkdir (shells do this better), window management, label/tag editing, desktop settings.
- Paths: actions expand `~` and relativize to absolute via FileManager; nonexistent path for reveal/open/trash → clean `notFound` BEFORE any AppleScript. Trash by exact path only.
- `eject`: case-insensitive name match against `disks` output; unknown → notFound naming `mac finder disks`; non-ejectable → badInput.
- All conventions carry: escape everything, timeouts, no `whose`, FS/RS records, --json/--quiet, emitConfirmation ("trashed", "ejected"; reveal/open → "revealed"/"opened" with the path), exit codes, locked schemas.

## Models (Core)

- `FinderItem` — `path`, `name`, `kind` (Finder's kind string, e.g. "Folder", "PNG image")
- `DiskInfo` — `name`, `capacityBytes`, `freeBytes`, `ejectable` (Bool)

## Architecture

Established pattern: `FinderModule/` (FinderStore, FinderActions, FinderScripts, AppleScriptFinderStore, FinderCommand). Scripts: `selection as alias list` → POSIX paths (per-item `POSIX path of`), `reveal (POSIX file "...")` + `activate`, `open (POSIX file "...")`, `delete (POSIX file "...")` (→ Trash), disks via `every disk` bulk name/capacity/free/ejectable (as list; ledger: object ranges don't as-list — index disks directly per item), `eject disk "..."`. Doctor: `automation:Finder` (com.apple.finder, hint "finder"). Gotcha ledger applies in full.

## Error handling

Missing path → notFound (pre-checked in Swift). Finder refusals (e.g. eject busy volume) → REFUSED-sentinel → badInput carrying Finder's message (v4 pattern). Consent -1743 → permissionDenied. Selection empty → empty list (not an error).

## Testing

Mock-backed actions tests (path expansion/validation, unknown disk, non-ejectable guard); builder tests (escape/timeout/no-whose/sentinels); store parse tests (records, dedupe n/a — no ids — skip dedupe, malformed warn); parse-only CLI tests. Smoke: `selection` (any result ok), `disks`, `reveal` + `trash` round-trip on a scratch file created by the smoke script itself (trash it, verify gone from original path), eject skipped (no guaranteed removable volume). Live pass: coordinator, incl. eject dry-check via disks list only.

## README

Usage examples; limitation notes (trash-only deletion, no file ops by design — "use your shell"); roadmap → "iWork — Keynote/Pages/Numbers (v6), Homebrew tap."
