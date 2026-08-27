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

echo "PASS"
