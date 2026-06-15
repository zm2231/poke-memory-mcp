#!/usr/bin/env bash
set -uo pipefail
APP_DIR="${POKE_APP_DIR:-$HOME/poke-memory}"
ts() { date -u +%Y-%m-%dT%H:%M:%S+00:00; }

echo "$(ts) ingest start"
"$APP_DIR/.venv/bin/python" "$APP_DIR/export_messages.py"
rc=$?
echo "$(ts) export rc=$rc"
if [ "$rc" -eq 0 ]; then
  bash "$APP_DIR/reindex.sh" raw
  rrc=$?
  echo "$(ts) reindex raw rc=$rrc"
  [ "$rrc" -eq 0 ] || exit "$rrc"
else
  echo "$(ts) export failed; skipped reindex (is imsg installed and Full Disk Access granted?)"
  exit "$rc"
fi
