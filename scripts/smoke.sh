#!/bin/bash
# Local-only integration smoke test against the REAL Calendar/Reminders/Contacts.
# Requires granted TCC permissions (check with: mac doctor). Not run in CI.
# Creates its own items and deletes them; leaves no residue on success.
set -euo pipefail

MAC="${MAC:-.build/release/mac}"

json_field() { /usr/bin/python3 -c "import json,sys; print(json.load(sys.stdin)[\"$1\"])"; }

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

echo "PASS"
