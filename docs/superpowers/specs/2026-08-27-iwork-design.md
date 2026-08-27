# mac-cli v6 Design — iWork (Keynote, Pages, Numbers)

**Date:** 2026-08-27
**Status:** Approved (single-pass build)
**Builds on:** v1–v5 (all shipped; full gotcha ledger applies)

## Purpose

Three document-creation modules: `mac keynote`, `mac pages`, `mac numbers`. The agent story: create documents, inspect open ones, make targeted edits, and export to interchange formats — so agents can produce real deliverables (a deck, a letter, a sheet) that open in the apps people actually use. Dictionaries: Keynote 28 cmds/22 classes, Pages 11/23, Numbers 16/21 (surveyed).

## Shared iWork realities that shape the design

- iWork scripting operates on OPEN documents. `docs` lists them; `new` creates (and opens) one; other verbs address open documents by NAME (iWork documents expose no stable scripting id — name addressing with the established ambiguity rejection; documents are few, so this is safe).
- `new` can take `--out <path>`: the document is saved there immediately (`save ... in POSIX file`), giving it a durable identity; without --out it stays unsaved ("Untitled").
- `export` writes to a caller-given path via `export ... to POSIX file ... as <format>`; formats per app below. Export paths: parent directory must exist (precheck → notFound); existing file → overwritten only with `--force`, else badInput (new rule — exports are the one place agents write arbitrary paths).
- All conventions + gotcha ledger carry over (escape everything, timeouts, no whose — name addressing uses `document "<escaped name>"` direct specifiers, REFUSED sentinels on app refusals, object ranges never as-list, reserved-word vigilance: `it`, `st`, `names` already burned).

## Command surface

```
mac keynote docs
mac keynote new [--theme "White"] [--out path.key]
mac keynote add-slide <doc> --title "..." [--body "..."]     # appends a slide
mac keynote slides <doc>                                      # slide count + titles
mac keynote export <doc> --format pdf|pptx --out path [--force]

mac pages docs
mac pages new [--out path.pages]
mac pages get-body <doc>                                      # body text (payload output)
mac pages set-body <doc> --text "..."                         # replaces body text
mac pages append <doc> --text "..."                           # appends a paragraph
mac pages export <doc> --format pdf|docx --out path [--force]

mac numbers docs
mac numbers new [--out path.numbers]
mac numbers get-cell <doc> --cell B2 [--sheet 1] [--table 1]
mac numbers set-cell <doc> --cell B2 --value "42" [--sheet 1] [--table 1]
mac numbers export <doc> --format pdf|xlsx|csv --out path [--force]
```

- `<doc>` is the document NAME as shown in `docs` (ambiguity → badInput listing names; unknown → notFound "Run: mac <app> docs").
- Numbers sheet/table are 1-based indexes (names too fiddly across locales); cell is A1-notation validated by regex `^[A-Za-z]{1,3}[0-9]{1,7}$`. set-cell writes the value as text (Numbers coerces numerics itself).
- Keynote add-slide: `make new slide at end` + set the default title/body item text; theme on `new` resolved case-insensitively against `name of every theme`, unknown → notFound listing first few.
- Models (Core): `IWorkDocInfo` — `name`, `path?` (nil when unsaved), `modified` (Bool, "has unsaved changes"); `SlideInfo` — `number`, `title`. get-body/get-cell outputs are payloads (raw print / {"body":...} / {"value":...} via JSONSerialization — never interpolation).

## Error handling

Unknown doc/theme → notFound with discovery hint; ambiguous doc name → badInput; invalid cell ref / unknown format / missing parent dir / existing file without --force → badInput (existing-file message says "pass --force to overwrite"); app refusals (locked/read-only docs) → REFUSED → badInput; -1743 → permissionDenied. Doctor: `automation:Keynote` (com.apple.iWork.Keynote), `automation:Pages` (com.apple.iWork.Pages), `automation:Numbers` (com.apple.iWork.Numbers) — 14 rows total.

## Non-goals (v6)

Slide reordering/deletion, images/media insertion, styling/formatting, per-paragraph Pages edits, Numbers formulas/ranges/charts, templates beyond Keynote themes, printing, collaboration state. Documents are never closed or saved implicitly by mac (except `new --out`'s initial save and export writing its own file).

## Testing

Established stack per module (mock actions incl. ambiguity + export --force rules + cell-ref validation; builder tests incl. escaping/timeout/no-whose/REFUSED; store parse tests; parse-only CLI). osacompile every variant. Smoke: per app — `docs` (open-doc listing tolerant of zero), then a full round-trip in the scratchpad: `new --out` → mutate (add-slide / set-body / set-cell) → export pdf → verify file exists and is non-empty → trash both files via `mac finder trash`. Live pass: coordinator runs the same round-trips against real apps and inspects the exported PDFs.

## README

Usage examples; For agents: exports overwrite only with --force; Known limitations (name addressing, open-document model, text-only edits); scriptability table rows flip; Roadmap → "Homebrew tap."
