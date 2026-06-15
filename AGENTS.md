# Installing poke-memory-mcp (for an AI agent)

This repo sets up a local MCP server on **macOS** that gives Poke a durable, searchable markdown memory vault, exposed over a tunnel. You can install it unattended. There are two paths:

- **Interactive (a human runs it):** `./install.sh` — a guided wizard. Don't use this headless; it reads prompts from the terminal.
- **Headless (you, the agent, run it):** write `deploy/.env`, then run `bash deploy/setup.sh`. `setup.sh` reads nothing from the terminal and does the whole install.

## Headless steps

1. Copy `deploy/.env.example` to `deploy/.env` and fill it in (keys below). Keep it `chmod 600`.
2. Run `bash deploy/setup.sh`. It creates the venv, installs deps, builds the index, renders + loads the launchd services, sets up ingress, and prints the `npx poke mcp add ...` command.
3. Verify: `poke-vault doctor` (and `poke-vault status`). All checks should be green.
4. Register with Poke using the printed command (`npx poke@latest mcp add https://<host>/mcp -k "$(cat <app-dir>/.token)"`).

## deploy/.env keys

Required: `POKE_APP_DIR`, `POKE_VAULT_ROOT`, `POKE_VAULT_PORT` (default 8077), `EMBED_MODE`, `EMBED_MODEL`, `INGRESS`.

Embeddings:
- `EMBED_MODE=sentence-transformers` + `EMBED_MODEL=BAAI/bge-small-en-v1.5` — local, no API, no network dependency. Use this unless the user has a reason not to.
- `EMBED_MODE=openai` + `EMBED_API_BASE` + `EMBED_API_KEY` + `EMBED_MODEL` — any OpenAI-compatible endpoint (ollama at `http://127.0.0.1:11434/v1`, OpenAI, an internal server).

Ingress (Poke is a cloud service and needs a public HTTPS URL):
- `INGRESS=cfapi` — **the unattended path, no browser.** Set `CLOUDFLARED_BIN` (path to cloudflared), `CF_API_TOKEN` (scoped: Account > Cloudflare Tunnel: Edit, Zone > DNS: Edit + Zone: Read), `CF_ACCOUNT_ID`, `CF_HOSTNAME` (e.g. `memory.user-domain.com`), `CF_TUNNEL_NAME` (default `poke-memory`). setup.sh creates the tunnel, configures ingress, routes DNS, and runs the connector — all over the CF API.
- `INGRESS=quick` runs an instant Cloudflare quick tunnel as a launchd service (no account; the URL is ephemeral and changes on restart). After install, get the current URL and the exact Poke registration command with `poke-vault tunnel-url`.
- `INGRESS=named` — Cloudflare named tunnel via `cloudflared tunnel login` (browser OAuth). **You cannot complete this unattended;** use `cfapi` instead.

## Safety (do not skip)

- The vault holds the user's personal data. If you set up a git remote for it (so `vault_sync` works), the repo **must be private**. Never push it to a public repo.
- **Message ingest needs Full Disk Access, which you cannot grant.** launchd jobs do not inherit it. Tell the user, step by step: open System Settings, Privacy & Security, Full Disk Access; click +; in the file picker press Cmd+Shift+G (the `.venv` path is hidden, so the picker will not show it otherwise); paste the exact path `<app-dir>/.venv/bin/python`; select it and toggle it on. The scheduled job fails closed until then (`poke-vault doctor` flags it). `poke-vault ingest` from a Full Disk Access terminal works meanwhile.
- Secrets (`CF_API_TOKEN`, `EMBED_API_KEY`, the bearer token) live in `deploy/.env`, `<app-dir>/.token`, `<app-dir>/config.env`, `<app-dir>/.cf_tunnel_token` — all gitignored and mode 600. Never print them or commit them.
- Get the user's confirmation before creating cloud resources (a Cloudflare tunnel + DNS record) or registering with Poke.

## Managing it after install

`poke-vault status | doctor | sync | reindex | logs | rules | uninstall` (installed on PATH).
