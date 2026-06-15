#!/usr/bin/env bash
set -uo pipefail
APP_DIR="${POKE_APP_DIR:-$HOME/poke-memory}"
VENV="$APP_DIR/.venv/bin"
VAULT="${POKE_VAULT_ROOT:-$HOME/poke-vault}"
IDX="$APP_DIR/.leann/indexes"
MODEL="${EMBED_MODEL:-BAAI/bge-small-en-v1.5}"
EMBED_MODE="${EMBED_MODE:-sentence-transformers}"
EMBED_API_BASE="${EMBED_API_BASE:-}"
EMBED_API_KEY="${EMBED_API_KEY:-iq-local}"
LOG="$APP_DIR/reindex.log"
LOCKFILE="$APP_DIR/.reindex.lock"
MODE="${1:-full}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$APP_DIR" || exit 1
mkdir -p "$VAULT"/{projects,people,inbox,.vault}

CANON=()
while IFS= read -r d; do [ -n "$d" ] && CANON+=("$VAULT/$d"); done < <(
  "$VENV/python" -c 'import sys; sys.path.insert(0, sys.argv[1]); import vault_manifest; print("\n".join(vault_manifest.canon_dirs(sys.argv[2])))' "$APP_DIR" "$VAULT" 2>/dev/null
)
[ ${#CANON[@]} -eq 0 ] && CANON=("$VAULT/projects" "$VAULT/people")
mkdir -p "${CANON[@]}"

ts() { date -u +%Y-%m-%dT%H:%M:%S+00:00; }

if [ "${REINDEX_LOCKED:-0}" != "1" ]; then
  export REINDEX_LOCKED=1
  exec "$VENV/python" -c 'import fcntl,os,subprocess,sys
fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o644)
try:
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(0)
sys.exit(subprocess.call(sys.argv[2:]))' "$LOCKFILE" /bin/bash "$SELF" "$@"
fi

rotate() {
  local f="$1" max="${2:-5242880}" t sz
  [ -f "$f" ] || return 0
  sz=$(stat -f %z "$f" 2>/dev/null || echo 0)
  [ "$sz" -gt "$max" ] || return 0
  t=$(mktemp) || return 0
  tail -n 500 "$f" > "$t" 2>/dev/null && cat "$t" > "$f"
  rm -f "$t"
}
rotate "$LOG"

echo "$(ts) reindex start mode=$MODE" >> "$LOG"

build() {
  local name="$1"; shift
  local emb=(--embedding-mode "$EMBED_MODE" --embedding-model "$MODEL" --no-recompute)
  [ -n "$EMBED_API_BASE" ] && emb+=(--embedding-api-base "$EMBED_API_BASE" --embedding-api-key "$EMBED_API_KEY")
  local force=()
  [ "${POKE_REINDEX_FORCE:-0}" = "1" ] && force=(--force)
  "$VENV/leann" build "$name" --docs "$@" --file-types md "${emb[@]}" ${force[@]+"${force[@]}"} >> "$LOG" 2>&1 || return 1
  [ -f "$IDX/$name/documents.index" ] || return 1
  return 0
}

if [ "$MODE" = "raw" ]; then
  build poke-vault-raw "$VAULT/inbox"
  RAW=$?
  if [ "$RAW" -eq 0 ]; then
    ts > "$VAULT/.vault/reindex_stamp_raw"
    echo "$(ts) reindex OK (raw)" >> "$LOG"
    exit 0
  fi
  echo "$(ts) reindex FAILED raw=$RAW (raw mode)" >> "$LOG"
  echo "$(ts) raw=$RAW" > "$VAULT/.vault/reindex_failed"
  exit 1
fi

build poke-vault-canonical "${CANON[@]}"
CANON=$?

RAW=0
RAW_IDX="$IDX/poke-vault-raw/documents.index"
NEWEST=$(find "$VAULT/inbox" -name '*.md' -newer "$RAW_IDX" 2>/dev/null | head -1)
if [ ! -f "$RAW_IDX" ] || [ -n "$NEWEST" ]; then
  build poke-vault-raw "$VAULT/inbox"
  RAW=$?
fi

POKE_VAULT_ROOT="$VAULT" "$VENV/python" "$APP_DIR/gen_index.py" >> "$LOG" 2>&1
GEN=$?

if [ "$CANON" -eq 0 ] && [ "$RAW" -eq 0 ] && [ "$GEN" -eq 0 ]; then
  ts > "$VAULT/.vault/reindex_stamp"
  ts > "$VAULT/.vault/reindex_stamp_raw"
  rm -f "$VAULT/.vault/reindex_failed" 2>/dev/null
  echo "$(ts) reindex OK" >> "$LOG"
  exit 0
fi
echo "$(ts) reindex FAILED canon=$CANON raw=$RAW gen=$GEN" >> "$LOG"
echo "$(ts) canon=$CANON raw=$RAW gen=$GEN" > "$VAULT/.vault/reindex_failed"
exit 1
