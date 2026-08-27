#!/bin/bash
# Local-only integration smoke test against the REAL Calendar/Reminders/Contacts.
# Requires granted TCC permissions (check with: mac doctor). Not run in CI.
# Creates its own items and deletes them; leaves no residue on success.
set -euo pipefail

MAC="${MAC:-.build/release/mac}"

# Names the failing line instead of leaving a bare non-zero exit.
trap 'echo "smoke: FAILED at line $LINENO -- see the error above" >&2' ERR

# Extracts one field from JSON on stdin. Reports a clean diagnostic rather than a
# Python traceback when the command upstream failed and produced no JSON.
json_field() {
  /usr/bin/python3 -c '
import json, sys
field = sys.argv[1]
raw = sys.stdin.read()
if not raw.strip():
    sys.stderr.write("smoke: expected JSON from the previous command, got nothing "
                     "(it failed -- its error is printed above)\n")
    sys.exit(1)
try:
    data = json.loads(raw)
except ValueError:
    sys.stderr.write("smoke: previous command did not emit valid JSON:\n  %s\n" % raw[:200])
    sys.exit(1)
try:
    print(data[field])
except (KeyError, TypeError):
    sys.stderr.write("smoke: JSON has no field %r (got: %s)\n" % (field, raw[:200]))
    sys.exit(1)
' "$1"
}

echo "== doctor =="
"$MAC" doctor

echo "== calendar =="
EVENT_ID=$("$MAC" calendar add "mac-cli smoke event" --at "+2h" --duration 30m --json | json_field id)
"$MAC" calendar list --from today --to +1d | grep -q "mac-cli smoke event"
"$MAC" calendar edit "$EVENT_ID" --title "mac-cli smoke event (edited)" --json | json_field title | grep -q "(edited)"
"$MAC" calendar delete "$EVENT_ID" --quiet

echo "== reminders =="
REM_ID=$("$MAC" reminders add "mac-cli smoke reminder" --due "tomorrow 9am" --json | json_field id)
"$MAC" reminders list | grep -q "mac-cli smoke reminder"
"$MAC" reminders complete "$REM_ID" --json | json_field isCompleted | grep -q "True"
"$MAC" reminders delete "$REM_ID" --quiet

echo "== contacts =="
CONTACT_ID=$("$MAC" contacts add --name "Mac Smoketest" --email "smoke@example.com" --json | json_field id)
"$MAC" contacts find "Mac Smoketest" | grep -q "Mac Smoketest"
"$MAC" contacts show "$CONTACT_ID" --json | json_field name | grep -q "Mac Smoketest"
"$MAC" contacts delete "$CONTACT_ID" --quiet

echo "== mail =="
"$MAC" mail unread --limit 3 --scan 10 >/dev/null
"$MAC" mail search "mac-cli-smoke-should-match-nothing" --json | grep -q '\[\]'
"$MAC" mail draft --to "smoke@example.com" --subject "mac-cli smoke draft — safe to close" --body "Created by scripts/smoke.sh; close this window." --quiet
echo "   (a draft window opened in Mail — close it whenever)"

echo "== messages =="
if [ -n "${SMOKE_HANDLE:-}" ]; then
  "$MAC" messages chats --limit 3 >/dev/null
  "$MAC" messages send "$SMOKE_HANDLE" "mac-cli smoke test" --quiet
  sleep 2
  "$MAC" messages history "$SMOKE_HANDLE" --limit 5 | grep -q "mac-cli smoke test"
else
  "$MAC" messages chats --limit 3 >/dev/null
  echo "   (set SMOKE_HANDLE=+1555… to also test send+history round-trip)"
fi

echo "== notes =="
NOTE_ID=$("$MAC" notes add "mac-cli smoke note" --body "created by smoke" --json | json_field id)
"$MAC" notes append "$NOTE_ID" "appended line" --quiet
"$MAC" notes read "$NOTE_ID" --json | json_field body | grep -q "appended line"
"$MAC" notes edit "$NOTE_ID" --title "mac-cli smoke note (edited)" --quiet
"$MAC" notes list --limit 5 | grep -q "mac-cli smoke note"
"$MAC" notes folders >/dev/null
"$MAC" notes delete "$NOTE_ID" --quiet

echo "== music =="
"$MAC" music now >/dev/null
"$MAC" music playlists >/dev/null
# json_field expects a JSON object; search returns an array, so pull [0]["id"]
# with python directly. Tolerates an empty match (empty library, or nothing
# matches "a") by leaving TRACK_ID unset rather than failing the whole script.
TRACK_ID=$("$MAC" music search "a" --limit 1 --json | /usr/bin/python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    items = json.loads(raw)
    print(items[0]["id"])
except (ValueError, IndexError, KeyError, TypeError):
    pass
' || true)
PL_ID=$("$MAC" music playlist-create "mac-cli smoke playlist" --json | json_field id)
if [ -n "$TRACK_ID" ]; then
  "$MAC" music playlist-add "mac-cli smoke playlist" "$TRACK_ID" --quiet
  "$MAC" music playlist-remove "mac-cli smoke playlist" "$TRACK_ID" --quiet
  # Delete-semantics live check (Task 3's review): playlist-remove must only
  # unlink the track from the playlist, not delete it from the library --
  # re-run the same search and confirm the same track id still resolves.
  "$MAC" music search "a" --limit 1 --json | /usr/bin/python3 -c '
import json, sys
raw = sys.stdin.read()
items = json.loads(raw)
assert items and items[0]["id"] == "'"$TRACK_ID"'", "smoke: track vanished from the library after playlist-remove"
'
else
  echo "   (no track matched \"a\" in the library -- skipping playlist-add/remove)"
fi
"$MAC" music playlist-delete "mac-cli smoke playlist" --quiet

echo "== tv =="
"$MAC" tv list --limit 3 >/dev/null

echo "== shortcuts =="
"$MAC" shortcuts list >/dev/null

echo "== call (dry-run only -- never dials) =="
"$MAC" call "+15551234567" --dry-run | grep -q "tel:+15551234567"
"$MAC" facetime "smoke@example.com" --dry-run --audio | grep -q "facetime-audio://"

echo "== finder =="
SMOKE_FILE="$(mktemp /tmp/mac-cli-smoke-XXXXXX)"
echo hello > "$SMOKE_FILE"
"$MAC" finder disks >/dev/null
"$MAC" finder selection >/dev/null
"$MAC" finder trash "$SMOKE_FILE" --quiet
if [ -f "$SMOKE_FILE" ]; then
  echo "smoke: finder trash left the file in place" >&2
  exit 1
fi
echo "   (trash verified: file left original location)"

echo "PASS"
