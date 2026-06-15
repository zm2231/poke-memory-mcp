#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVF="$HERE/deploy/.env"

bold(){ printf "\033[1m%s\033[0m\n" "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }
ask(){
  local __var=$1 __prompt=$2 __def=${3:-} __in=""
  if [ -n "$__def" ]; then printf "%s [%s]: " "$__prompt" "$__def" >&2; else printf "%s: " "$__prompt" >&2; fi
  read -r __in </dev/tty || __in=""
  printf -v "$__var" "%s" "${__in:-$__def}"
}
pause(){ printf "%s" "$1" >&2; read -r _ </dev/tty || true; }
asks(){
  local __var=$1 __prompt=$2 __in=""
  printf "%s: " "$__prompt" >&2
  read -rs __in </dev/tty || __in=""
  printf "\n" >&2
  printf -v "$__var" "%s" "$__in"
}

bold "poke-memory-mcp installer"
echo "Gives Poke a durable, semantically-searchable markdown memory vault on this Mac."
echo

[ "$(uname)" = "Darwin" ] || { echo "This installer targets macOS (launchd). Aborting." >&2; exit 1; }
have python3 || { echo "python3 not found. Install it (brew install python) and re-run." >&2; exit 1; }
PYV=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')
echo "python3 $PYV detected"
have git || echo "note: git not found — the vault_sync tool stays unavailable until you install git."

echo
bold "Locations"
ask BASE "Install location (holds the app + your vault)" "$HOME"
ask POKE_APP_DIR "  app dir (code + venv + index)" "$BASE/poke-memory"
ask POKE_VAULT_ROOT "  vault dir (your markdown memory)" "$BASE/poke-vault"
ask POKE_VAULT_PORT "Local port" "8077"

echo
bold "Embeddings"
EMBED_MODE="sentence-transformers"; EMBED_MODEL="BAAI/bge-small-en-v1.5"; EMBED_API_BASE=""; EMBED_API_KEY=""
OLLAMA_MODELS=""
have ollama && OLLAMA_MODELS=$(ollama list 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ' || true)
echo "  1) local sentence-transformers — no API, runs offline [default]"
if [ -n "$OLLAMA_MODELS" ]; then echo "  2) ollama (detected: $OLLAMA_MODELS)"; else echo "  2) ollama (not detected on this machine)"; fi
echo "  3) other OpenAI-compatible endpoint (OpenAI, an internal server, etc.)"
ask EMB_CHOICE "Choose embeddings" "1"
case "$EMB_CHOICE" in
  2) EMBED_MODE="openai"; EMBED_API_BASE="http://127.0.0.1:11434/v1"; EMBED_API_KEY="ollama"
     ask EMBED_MODEL "Ollama embedding model" "${OLLAMA_MODELS%% *}"
     [ -n "$EMBED_MODEL" ] || EMBED_MODEL="bge-m3" ;;
  3) EMBED_MODE="openai"
     ask EMBED_API_BASE "API base URL (…/v1)" "https://api.openai.com/v1"
     asks EMBED_API_KEY "API key (hidden)"
     ask EMBED_MODEL "Embedding model" "text-embedding-3-small" ;;
  *) echo "    using local $EMBED_MODEL" ;;
esac

echo
bold "Ingress — how Poke reaches this server (it needs a stable public HTTPS URL)"
echo "  1) Cloudflare named tunnel, browser login — stable URL, interactive [recommended]"
echo "  2) Cloudflare named tunnel, API token — stable URL, no browser (agent-friendly)"
echo "  3) ngrok — quick public URL, needs an ngrok account/authtoken"
echo "  4) Cloudflare quick tunnel — instant, but the URL changes on every restart"
echo "  5) Tailscale / localhost only — private; Poke's cloud cannot reach it without extra setup"
ask ING_CHOICE "Choose ingress" "1"
case "$ING_CHOICE" in
  2) INGRESS="cfapi" ;;
  3) INGRESS="ngrok" ;;
  4) INGRESS="quick" ;;
  5) INGRESS="tailscale" ;;
  *) INGRESS="named" ;;
esac

CLOUDFLARED_BIN=""; CF_TUNNEL_NAME="poke-memory"; CF_TUNNEL_ID=""; CF_CRED_FILE=""; CF_HOSTNAME=""
CF_API_TOKEN=""; CF_ACCOUNT_ID=""; NGROK_BIN=""
if [ "$INGRESS" = "named" ]; then
  have cloudflared || { echo "cloudflared not found. Install it (brew install cloudflared) and re-run." >&2; exit 1; }
  CLOUDFLARED_BIN="$(command -v cloudflared)"
  if ! cloudflared tunnel list >/dev/null 2>&1; then
    echo
    echo "cloudflared is not authenticated with your Cloudflare account yet."
    echo "Run this in another terminal (it opens a browser; pick the zone for your domain):"
    echo "    cloudflared tunnel login"
    pause "Press Enter once login finished... "
    cloudflared tunnel list >/dev/null 2>&1 || { echo "still not authenticated; aborting." >&2; exit 1; }
  fi
  ask CF_TUNNEL_NAME "Tunnel name" "poke-memory"
  ask CF_HOSTNAME "Public hostname for Poke (e.g. memory.yourdomain.com)" ""
  [ -n "$CF_HOSTNAME" ] || { echo "a hostname is required for a named tunnel." >&2; exit 1; }
  CF_TUNNEL_ID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$CF_TUNNEL_NAME" '$2==n{print $1}' | head -1)"
  if [ -z "$CF_TUNNEL_ID" ]; then
    echo "creating tunnel $CF_TUNNEL_NAME ..."
    cloudflared tunnel create "$CF_TUNNEL_NAME" >&2
    CF_TUNNEL_ID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$CF_TUNNEL_NAME" '$2==n{print $1}' | head -1)"
  fi
  [ -n "$CF_TUNNEL_ID" ] || { echo "could not resolve the tunnel id." >&2; exit 1; }
  CF_CRED_FILE="$HOME/.cloudflared/${CF_TUNNEL_ID}.json"
  echo "tunnel $CF_TUNNEL_NAME -> $CF_TUNNEL_ID"
fi

if [ "$INGRESS" = "cfapi" ]; then
  have cloudflared || { echo "cloudflared not found. Install it (brew install cloudflared) and re-run." >&2; exit 1; }
  CLOUDFLARED_BIN="$(command -v cloudflared)"
  echo
  echo "Create a Cloudflare API token (dashboard > My Profile > API Tokens) with permissions:"
  echo "  Account > Cloudflare Tunnel: Edit   and   Zone > DNS: Edit + Zone: Read"
  asks CF_API_TOKEN "Cloudflare API token (hidden)"
  ask CF_ACCOUNT_ID "Cloudflare account id" ""
  ask CF_HOSTNAME "Public hostname (e.g. memory.yourdomain.com)" ""
  ask CF_TUNNEL_NAME "Tunnel name" "poke-memory"
  { [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ACCOUNT_ID" ] && [ -n "$CF_HOSTNAME" ]; } || \
    { echo "API token, account id, and hostname are all required." >&2; exit 1; }
fi

if [ "$INGRESS" = "quick" ]; then
  have cloudflared || { echo "cloudflared not found. Install it (brew install cloudflared) and re-run." >&2; exit 1; }
  CLOUDFLARED_BIN="$(command -v cloudflared)"
fi
if [ "$INGRESS" = "ngrok" ]; then
  have ngrok || { echo "ngrok not found. Install it (brew install ngrok), run 'ngrok config add-authtoken <token>', then re-run." >&2; exit 1; }
  NGROK_BIN="$(command -v ngrok)"
fi

echo
bold "Message ingest"
echo "Keep the Poke iMessage thread captured into the vault on a daily schedule (Poke doesn't store transcripts)."
echo "Needs the 'imsg' CLI installed and Full Disk Access granted to the ingest job."
ask INGEST_CHOICE "Enable automatic message ingest? [Y/n]" "Y"
case "$INGEST_CHOICE" in n|N|no|NO) INGEST=0 ;; *) INGEST=1 ;; esac

echo
bold "Writing $ENVF"
mkdir -p "$HERE/deploy"
envq(){ printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"; }
{
  envq POKE_APP_DIR "$POKE_APP_DIR"
  envq POKE_VAULT_ROOT "$POKE_VAULT_ROOT"
  envq POKE_VAULT_PORT "$POKE_VAULT_PORT"
  envq POKE_VAULT_STALE_AFTER "3600"
  envq REINDEX_INTERVAL "900"
  envq POKE_VECTOR_WEIGHT "0.7"
  envq EMBED_MODE "$EMBED_MODE"
  envq EMBED_MODEL "$EMBED_MODEL"
  envq EMBED_API_BASE "$EMBED_API_BASE"
  envq EMBED_API_KEY "$EMBED_API_KEY"
  envq INGRESS "$INGRESS"
  envq CLOUDFLARED_BIN "$CLOUDFLARED_BIN"
  envq CF_TUNNEL_NAME "$CF_TUNNEL_NAME"
  envq CF_TUNNEL_ID "$CF_TUNNEL_ID"
  envq CF_CRED_FILE "$CF_CRED_FILE"
  envq CF_HOSTNAME "$CF_HOSTNAME"
  envq CF_API_TOKEN "$CF_API_TOKEN"
  envq CF_ACCOUNT_ID "$CF_ACCOUNT_ID"
  envq NGROK_BIN "$NGROK_BIN"
  envq INGEST "$INGEST"
  envq INGEST_INTERVAL "86400"
  envq POKE_NAME_REGEX '^poke$'
} > "$ENVF"
chmod 600 "$ENVF"

echo
bold "Installing (venv, deps, build index, load services) — first run downloads the model, give it a minute."
bash "$HERE/deploy/setup.sh"

echo
case "$INGRESS" in
  ngrok)
    bold "ngrok tunnel is running as a launchd service"
    echo "Its URL is dynamic. Get the current URL and the exact Poke command with:"
    echo "    poke-vault tunnel-url"
    echo "(If it has no URL, run 'ngrok config add-authtoken <token>' once, then 'poke-vault status'.)" ;;
  quick)
    bold "Cloudflare quick tunnel is running as a launchd service"
    echo "Its URL is ephemeral (changes on restart). Get the current URL and the exact Poke command with:"
    echo "    poke-vault tunnel-url" ;;
  tailscale)
    bold "Private / Tailscale"
    echo "The server is bound to 127.0.0.1:$POKE_VAULT_PORT. Poke's cloud cannot reach a tailnet/localhost"
    echo "address, so this mode is for local dev (e.g. the Poke CLI on this Mac) or your own added ingress." ;;
esac
echo
bold "Customize the rules your agents follow"
echo "Edit $POKE_VAULT_ROOT/docs/voice.md (your voice + write playbook) and"
echo "     $POKE_VAULT_ROOT/docs/vault-operating-procedure.md — or run: poke-vault rules --edit"
echo "vault_rules serves whatever is in those files; agents pull them before writing."
if [ "${INGEST:-0}" = "1" ]; then
  echo
  bold "One manual step for scheduled message ingest"
  echo "The daily ingest job runs under launchd, which does NOT inherit Full Disk Access."
  echo "Grant it:"
  echo "  1. Open System Settings > Privacy & Security > Full Disk Access"
  echo "  2. Click + . In the file picker press Cmd+Shift+G (the .venv path is hidden)"
  echo "  3. Paste this exact path and pick the file, then toggle it on:"
  echo "       $POKE_APP_DIR/.venv/bin/python"
  echo "Until then the scheduled run fails (poke-vault doctor flags it). 'poke-vault ingest' from your terminal works now."
fi
echo
bold "Manage it later"
echo "  poke-vault status | doctor | sync | reindex | ingest | rotate-token | logs | rules | uninstall"
echo
bold "Done."
