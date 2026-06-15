#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"

[ -f "$HERE/.env" ] || { echo "missing $HERE/.env — copy .env.example and edit (or run ../install.sh)"; exit 1; }
chmod 600 "$HERE/.env" 2>/dev/null || true
set -a; . "$HERE/.env"; set +a

: "${POKE_APP_DIR:?}" "${POKE_VAULT_ROOT:?}" "${POKE_VAULT_PORT:?}" "${EMBED_MODEL:?}" "${EMBED_MODE:?}"
EMBED_API_BASE="${EMBED_API_BASE:-}"
EMBED_API_KEY="${EMBED_API_KEY:-}"
INGRESS="${INGRESS:-named}"
INGEST="${INGEST:-1}"
export NGROK_BIN="${NGROK_BIN:-}"
export INGEST_INTERVAL="${INGEST_INTERVAL:-86400}"
export POKE_NAME_REGEX="${POKE_NAME_REGEX:-^poke$}"
export POKE_NUMBERS="${POKE_NUMBERS:-}"
export POKE_IDENTIFIERS="${POKE_IDENTIFIERS:-}"
LA="$HOME/Library/LaunchAgents"
CF_CONFIG="$HOME/.cloudflared/config-poke-memory.yml"

if [ "$INGRESS" = "named" ]; then
  : "${CLOUDFLARED_BIN:?}" "${CF_TUNNEL_NAME:?}" "${CF_TUNNEL_ID:?}" "${CF_CRED_FILE:?}" "${CF_HOSTNAME:?}"
fi
if [ "$INGRESS" = "cfapi" ]; then
  : "${CLOUDFLARED_BIN:?}" "${CF_API_TOKEN:?}" "${CF_ACCOUNT_ID:?}" "${CF_HOSTNAME:?}"
fi
if [ "$INGRESS" = "quick" ]; then : "${CLOUDFLARED_BIN:?}"; fi
if [ "$INGRESS" = "ngrok" ]; then : "${NGROK_BIN:?}"; fi
if [ "$EMBED_MODE" = "openai" ]; then
  : "${EMBED_API_BASE:?EMBED_API_BASE required when EMBED_MODE=openai}"
fi

echo "==> preflight"
if command -v lsof >/dev/null 2>&1; then
  LPID=$(lsof -nP -iTCP:"$POKE_VAULT_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1) || true
  if [ -n "$LPID" ]; then
    MCPID=$(launchctl list com.poke.vault-mcp 2>/dev/null | awk -F'= ' '/"PID"/{gsub(/[^0-9]/,"",$2);print $2}')
    if [ "$LPID" != "${MCPID:-x}" ]; then
      echo "!! port $POKE_VAULT_PORT is held by pid $LPID, which is not this install's MCP service." >&2
      echo "!! Pick a different POKE_VAULT_PORT or stop that process. Aborting." >&2
      exit 1
    fi
  fi
fi
EXISTING_PLIST="$LA/com.poke.vault-mcp.plist"
if [ -f "$EXISTING_PLIST" ]; then
  PREV_DIR=$(sed -n 's#.*<string>\(/.*\)/vault_mcp.py</string>.*#\1#p' "$EXISTING_PLIST" | head -1)
  if [ -n "$PREV_DIR" ] && [ "$PREV_DIR" != "$POKE_APP_DIR" ] && [ "${POKE_FORCE:-0}" != "1" ]; then
    echo "!! An existing poke-memory install is registered at: $PREV_DIR" >&2
    echo "!! Installing here ($POKE_APP_DIR) would replace its launchd services (labels are global)." >&2
    echo "!! Re-run with POKE_FORCE=1 to replace it, or 'poke-vault uninstall' the other one first. Aborting." >&2
    exit 1
  fi
fi

echo "==> app dir: $POKE_APP_DIR   vault: $POKE_VAULT_ROOT   ingress: $INGRESS"
mkdir -p "$POKE_APP_DIR" "$LA" "$POKE_VAULT_ROOT"/{projects,people,inbox,.vault,docs}

echo "==> sync code"
for f in vault_mcp.py vault_manifest.py reindex.sh gen_index.py lint.py audit_client.py export_messages.py ingest.sh; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$POKE_APP_DIR/$f"
done
chmod +x "$POKE_APP_DIR/reindex.sh" "$POKE_APP_DIR/ingest.sh"
for d in vault-operating-procedure.md voice.md; do
  [ -f "$POKE_VAULT_ROOT/docs/$d" ] || { [ -f "$SRC/sample-vault/docs/$d" ] && cp "$SRC/sample-vault/docs/$d" "$POKE_VAULT_ROOT/docs/$d"; }
done

echo "==> venv + deps"
[ -d "$POKE_APP_DIR/.venv" ] || python3 -m venv "$POKE_APP_DIR/.venv"
PIP="$POKE_APP_DIR/.venv/bin/pip"
"$PIP" install -q --upgrade pip
"$PIP" install -q openai pyyaml uvicorn httpx "mcp[cli]"
[ "$EMBED_MODE" = "sentence-transformers" ] && "$PIP" install -q sentence-transformers
"$PIP" install -q leann
if [ -n "${LEANN_SRC:-}" ]; then
  "$PIP" install -q -e "$LEANN_SRC"
fi

EMB=$("$POKE_APP_DIR/.venv/bin/python" -c "import leann.embedding_compute as e;print(e.__file__)" 2>/dev/null || true)
if [ "$EMBED_MODE" = "openai" ]; then
  if [ -n "$EMB" ] && grep -q "LEANN_OPENAI_TIMEOUT" "$EMB" 2>/dev/null; then
    echo "    leann honors LEANN_OPENAI_TIMEOUT (stalled-embedding worker self-free active)"
  elif [ "${POKE_ALLOW_UNSAFE_EMBED:-0}" = "1" ]; then
    echo "!! WARNING: leann does NOT honor LEANN_OPENAI_TIMEOUT; a stalled remote embed can pin a worker ~600s." >&2
    echo "!! Proceeding anyway because POKE_ALLOW_UNSAFE_EMBED=1." >&2
  else
    echo "!! installed leann does NOT honor LEANN_OPENAI_TIMEOUT. With EMBED_MODE=openai a stalled remote embed" >&2
    echo "!! can pin a search worker ~600s and exhaust the pool, so recall silently goes dark." >&2
    echo "!! Fix: set LEANN_SRC to the patched leann-core fork and re-run. To override (not recommended): POKE_ALLOW_UNSAFE_EMBED=1." >&2
    echo "!! Aborting (not loading services)." >&2
    exit 1
  fi
fi

echo "==> token"
if [ ! -f "$POKE_APP_DIR/.token" ]; then
  "$POKE_APP_DIR/.venv/bin/python" -c "import secrets;print(secrets.token_urlsafe(32))" > "$POKE_APP_DIR/.token"
  echo "    generated $POKE_APP_DIR/.token"
fi
chmod 600 "$POKE_APP_DIR/.token"

PY="$POKE_APP_DIR/.venv/bin/python"
render() {
  RENDER_STALE_AFTER="${POKE_VAULT_STALE_AFTER:-3600}" RENDER_INTERVAL="${REINDEX_INTERVAL:-900}" \
  RENDER_CF_CONFIG="$CF_CONFIG" "$PY" - "$1" "$2" <<'PY'
import sys, os
from xml.sax.saxutils import escape
repl = {
    "@@APP_DIR@@": os.environ["POKE_APP_DIR"],
    "@@VAULT_ROOT@@": os.environ["POKE_VAULT_ROOT"],
    "@@PORT@@": os.environ["POKE_VAULT_PORT"],
    "@@STALE_AFTER@@": os.environ["RENDER_STALE_AFTER"],
    "@@REINDEX_INTERVAL@@": os.environ["RENDER_INTERVAL"],
    "@@EMBED_MODE@@": os.environ["EMBED_MODE"],
    "@@EMBED_MODEL@@": os.environ["EMBED_MODEL"],
    "@@EMBED_API_BASE@@": os.environ.get("EMBED_API_BASE", ""),
    "@@EMBED_API_KEY@@": os.environ.get("EMBED_API_KEY", ""),
    "@@VECTOR_WEIGHT@@": os.environ.get("POKE_VECTOR_WEIGHT", "0.7"),
    "@@CLOUDFLARED_BIN@@": os.environ.get("CLOUDFLARED_BIN", ""),
    "@@CF_CONFIG@@": os.environ["RENDER_CF_CONFIG"],
    "@@CF_TUNNEL_NAME@@": os.environ.get("CF_TUNNEL_NAME", ""),
    "@@CF_TUNNEL_ID@@": os.environ.get("CF_TUNNEL_ID", ""),
    "@@CF_CRED_FILE@@": os.environ.get("CF_CRED_FILE", ""),
    "@@CF_HOSTNAME@@": os.environ.get("CF_HOSTNAME", ""),
    "@@INGEST_INTERVAL@@": os.environ.get("INGEST_INTERVAL", "86400"),
    "@@POKE_NUMBERS@@": os.environ.get("POKE_NUMBERS", ""),
    "@@POKE_NAME_REGEX@@": os.environ.get("POKE_NAME_REGEX", "^poke$"),
    "@@POKE_IDENTIFIERS@@": os.environ.get("POKE_IDENTIFIERS", ""),
    "@@NGROK_BIN@@": os.environ.get("NGROK_BIN", ""),
}
src, dst = sys.argv[1], sys.argv[2]
xml = dst.endswith(".plist")
s = open(src).read()
for k, v in repl.items():
    s = s.replace(k, escape(v) if xml else v)
open(dst, "w").write(s)
PY
}

echo "==> render configs"
render "$HERE/com.poke.vault-mcp.plist.tmpl" "$LA/com.poke.vault-mcp.plist"
render "$HERE/com.poke.vault-reindex.plist.tmpl" "$LA/com.poke.vault-reindex.plist"
chmod 600 "$LA/com.poke.vault-mcp.plist" "$LA/com.poke.vault-reindex.plist"
if [ "$INGRESS" = "named" ]; then
  render "$HERE/config-poke-memory.yml.tmpl"      "$CF_CONFIG"
  render "$HERE/com.poke.vault-tunnel.plist.tmpl" "$LA/com.poke.vault-tunnel.plist"
fi

echo "==> initial index build"
if ! POKE_APP_DIR="$POKE_APP_DIR" POKE_VAULT_ROOT="$POKE_VAULT_ROOT" \
  EMBED_MODE="$EMBED_MODE" EMBED_MODEL="$EMBED_MODEL" \
  EMBED_API_BASE="$EMBED_API_BASE" EMBED_API_KEY="$EMBED_API_KEY" \
  bash "$POKE_APP_DIR/reindex.sh" full; then
  echo "!! initial index build FAILED — see $POKE_APP_DIR/reindex.log." >&2
  [ "$EMBED_MODE" = "openai" ] && echo "!! (check EMBED_API_BASE reachability / that the model is served there)." >&2
  echo "!! Not loading services; fix the cause and re-run." >&2
  exit 1
fi

echo "==> (re)load core launchd services"
for svc in com.poke.vault-mcp com.poke.vault-reindex; do
  launchctl unload "$LA/$svc.plist" 2>/dev/null || true
  launchctl load -w "$LA/$svc.plist"
done

if [ "$INGEST" = "1" ]; then
  echo "==> message-ingest service (daily; needs Full Disk Access + imsg)"
  render "$HERE/com.poke.vault-messages.plist.tmpl" "$LA/com.poke.vault-messages.plist"
  chmod 600 "$LA/com.poke.vault-messages.plist"
  launchctl unload "$LA/com.poke.vault-messages.plist" 2>/dev/null || true
  launchctl load -w "$LA/com.poke.vault-messages.plist"
else
  launchctl unload "$LA/com.poke.vault-messages.plist" 2>/dev/null || true
  rm -f "$LA/com.poke.vault-messages.plist"
fi

URL=""
if [ "$INGRESS" = "named" ]; then
  echo "==> route DNS (idempotent)"
  "$CLOUDFLARED_BIN" tunnel route dns "$CF_TUNNEL_NAME" "$CF_HOSTNAME" 2>/dev/null || \
    echo "    (route exists or hostname is in a non-cert zone — create the CNAME via the CF DNS API)"
  echo "==> load tunnel service"
  launchctl unload "$LA/com.poke.vault-tunnel.plist" 2>/dev/null || true
  launchctl load -w "$LA/com.poke.vault-tunnel.plist"
  URL="https://$CF_HOSTNAME/mcp"
elif [ "$INGRESS" = "cfapi" ]; then
  echo "==> create tunnel + configure ingress + route DNS via Cloudflare API"
  CF_TOKEN_OUT="$POKE_APP_DIR/.cf_tunnel_token" CF_API_TOKEN="$CF_API_TOKEN" CF_ACCOUNT_ID="$CF_ACCOUNT_ID" \
    CF_HOSTNAME="$CF_HOSTNAME" CF_TUNNEL_NAME="${CF_TUNNEL_NAME:-poke-memory}" POKE_VAULT_PORT="$POKE_VAULT_PORT" \
    python3 "$HERE/cf_api_tunnel.py"
  chmod 600 "$POKE_APP_DIR/.cf_tunnel_token"
  TT="$(cat "$POKE_APP_DIR/.cf_tunnel_token")" CLOUDFLARED_BIN="$CLOUDFLARED_BIN" "$PY" - \
    "$HERE/com.poke.vault-tunnel-token.plist.tmpl" "$LA/com.poke.vault-tunnel.plist" <<'PY'
import sys, os
from xml.sax.saxutils import escape
repl = {"@@CLOUDFLARED_BIN@@": os.environ["CLOUDFLARED_BIN"], "@@TUNNEL_TOKEN@@": os.environ["TT"]}
s = open(sys.argv[1]).read()
for k, v in repl.items():
    s = s.replace(k, escape(v))
open(sys.argv[2], "w").write(s)
PY
  chmod 600 "$LA/com.poke.vault-tunnel.plist"
  echo "==> load tunnel service"
  launchctl unload "$LA/com.poke.vault-tunnel.plist" 2>/dev/null || true
  launchctl load -w "$LA/com.poke.vault-tunnel.plist"
  URL="https://$CF_HOSTNAME/mcp"
elif [ "$INGRESS" = "quick" ]; then
  echo "==> Cloudflare quick tunnel service (ephemeral URL)"
  render "$HERE/com.poke.vault-tunnel-quick.plist.tmpl" "$LA/com.poke.vault-tunnel.plist"
  launchctl unload "$LA/com.poke.vault-tunnel.plist" 2>/dev/null || true
  launchctl load -w "$LA/com.poke.vault-tunnel.plist"
elif [ "$INGRESS" = "ngrok" ]; then
  echo "==> ngrok tunnel service (run 'ngrok config add-authtoken <token>' first if you have not)"
  render "$HERE/com.poke.vault-tunnel-ngrok.plist.tmpl" "$LA/com.poke.vault-tunnel.plist"
  launchctl unload "$LA/com.poke.vault-tunnel.plist" 2>/dev/null || true
  launchctl load -w "$LA/com.poke.vault-tunnel.plist"
fi

echo "==> write resolved config + install poke-vault CLI"
{
  printf 'POKE_APP_DIR=%q\n' "$POKE_APP_DIR"
  printf 'POKE_VAULT_ROOT=%q\n' "$POKE_VAULT_ROOT"
  printf 'POKE_VAULT_PORT=%q\n' "$POKE_VAULT_PORT"
  printf 'POKE_VAULT_INDEX=%q\n' "$POKE_APP_DIR/.leann/indexes/poke-vault-canonical/documents.leann"
  printf 'POKE_VAULT_RAW_INDEX=%q\n' "$POKE_APP_DIR/.leann/indexes/poke-vault-raw/documents.leann"
  printf 'INGRESS=%q\n' "$INGRESS"
  printf 'INGEST=%q\n' "$INGEST"
  printf 'POKE_NAME_REGEX=%q\n' "$POKE_NAME_REGEX"
  printf 'POKE_NUMBERS=%q\n' "$POKE_NUMBERS"
  printf 'POKE_IDENTIFIERS=%q\n' "$POKE_IDENTIFIERS"
  printf 'EMBED_MODE=%q\n' "$EMBED_MODE"
  printf 'EMBED_MODEL=%q\n' "$EMBED_MODEL"
  printf 'EMBED_API_BASE=%q\n' "$EMBED_API_BASE"
  printf 'EMBED_API_KEY=%q\n' "$EMBED_API_KEY"
  printf 'CF_HOSTNAME=%q\n' "${CF_HOSTNAME:-}"
  printf 'PUBLIC_URL=%q\n' "${URL:-}"
} > "$POKE_APP_DIR/config.env"
chmod 600 "$POKE_APP_DIR/config.env"

if [ -f "$SRC/poke-vault" ]; then
  cp "$SRC/poke-vault" "$POKE_APP_DIR/poke-vault"
  chmod +x "$POKE_APP_DIR/poke-vault"
  BIN="$HOME/.local/bin"
  mkdir -p "$BIN"
  ln -sf "$POKE_APP_DIR/poke-vault" "$BIN/poke-vault"
  case ":$PATH:" in
    *":$BIN:"*) : ;;
    *)
      case "${SHELL:-}" in
        */bash) RC="$HOME/.bashrc" ;;
        */zsh)  RC="$HOME/.zshrc" ;;
        *)      RC="$HOME/.profile" ;;
      esac
      LINE='export PATH="$HOME/.local/bin:$PATH"'
      grep -qsF "$LINE" "$RC" 2>/dev/null || printf '\n%s\n' "$LINE" >> "$RC"
      echo "    added $BIN to PATH in $RC (open a new terminal, or: source $RC)"
      ;;
  esac
  echo "    installed: poke-vault (status | doctor | sync | reindex | logs | rules | uninstall)"
fi

echo
echo "DONE. Server is live on 127.0.0.1:$POKE_VAULT_PORT (token in $POKE_APP_DIR/.token)."
if [ -n "$URL" ]; then
  echo "Register with Poke:"
  echo "  npx poke@latest mcp add $URL -k \$(cat $POKE_APP_DIR/.token)"
elif [ "$INGRESS" = "quick" ] || [ "$INGRESS" = "ngrok" ]; then
  echo "Tunnel service is running but its URL is dynamic. Get the current URL + the exact Poke command with:"
  echo "  poke-vault tunnel-url"
else
  echo "Ingress '$INGRESS' is not auto-managed here. Point your tunnel at http://127.0.0.1:$POKE_VAULT_PORT,"
  echo "then: npx poke@latest mcp add https://<your-public-url>/mcp -k \$(cat $POKE_APP_DIR/.token)"
fi
