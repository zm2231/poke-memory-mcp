# poke-memory-mcp

A secure MCP server that gives Poke durable, semantically-searchable memory over a markdown vault (`poke-vault`). Poke can recall context mid-conversation, write new facts, and promote them into canonical source-of-truth cards.

## Architecture

```
Poke ──HTTPS──> public URL/mcp ──> tunnel (Cloudflare / ngrok) ──> Mac (127.0.0.1:PORT)
                                                                        │
                                                          AuthASGI (bearer + rate limit + body cap)
                                                                        │
                                                                   FastMCP (vault_mcp.py)
                                                                        │
                          LEANN (local sentence-transformers, or a remote OpenAI-compatible embedder)
                                                                        │
                                            poke-vault/  (canonical cards + raw inbox)
```

launchd services keep it live:
- `com.poke.vault-mcp` — the MCP server (KeepAlive, pre-warms searchers).
- `com.poke.vault-reindex` — scheduled full reindex (default every 15 min), transactional with a freshness stamp.
- `com.poke.vault-tunnel` — the Cloudflare named tunnel (only when ingress = named tunnel; reboot-persistent).

## Tools exposed to Poke

| Tool | Purpose |
|---|---|
| `vault_search(query, type?, project?, person?, scope?, limit?, vector_weight?)` | Hybrid (vector + BM25/FTS5) search. `scope` = `canonical` (default) / `raw` / `all`. `vector_weight` 0–1: 1.0 pure semantic, 0.0 pure keyword, in between blends; omit to use the server default (`POKE_VECTOR_WEIGHT`, 0.7 out of the box), lower it for exact names/ids/phrases. Every response carries `freshness` (stale flag). |
| `vault_search_multi(queries)` | Run up to 8 searches in one call, each with its own query/weight/scope/filters; results grouped per query. Fire semantic + exact + per-person angles in one round trip. |
| `vault_search_messages(query?, sender?, date_from?, date_to?, limit?, context?)` | Search the raw iMessage history as individual messages (exact-substring terms, `sender` me/poke, date range), most-recent first, each with a surrounding-context window + source. For exact recall of what was said and when; semantic conversational queries stay on `vault_search`. |
| `vault_backlinks(path? \| slug?)` | Wikilink graph for a canonical card: outgoing `[[links]]` (resolved/dangling) + incoming references. Read-only; navigate relationships (e.g. person -> everything mentioning them). Operates on the canonical layer. |
| `vault_timeline(query, date_from?, date_to?, limit?)` | Chronological reconstruction for a query/entity: matching messages (precise timestamps) + canonical cards (frontmatter dates), earliest-first, each with blunt `date_provenance`. For 'when did X start / what changed / what happened after'. |
| `vault_query(where?, scope?, sort?, order?, limit?, fields?)` | Structured (Dataview-style) query over canonical card frontmatter: AND-ed `{field, op, value}` conditions (eq/ne/contains/in/exists/missing/lt/gt/lte/gte/startswith), sort + field selection. For exact metadata filters semantic search can't do (e.g. status=blocked, stage=proposal). |
| `vault_verify(claim, scope?, limit?)` | Fact-check a claim: retrieves evidence then an LLM judge (via iq chat) returns a conservative verdict (supported/contradicted/not_enough_evidence) + confidence + citing paths. Pre-flight 'do I actually know this'. Degrades to evidence-only if the judge is unavailable. |
| `vault_related(path?, query?, scope?, limit?)` | Associative recall: memories related to a card/topic, each tagged with why - `linked` ([[wikilinks]]), `shared_tag` (overlapping tags), `semantic` (vector). Works without hard links. |
| `vault_warm()` | Preload the embedding model so subsequent searches are fast (the backend unloads idle models after a few minutes). Call at the start of a session or cron/automation that runs several searches. |
| `vault_rules()` | Return the vault operating rules + voice/write playbook + cold-start onboarding (verbatim from `docs/vault-operating-procedure.md` + `docs/voice.md` + `docs/onboarding-playbook.md`) plus the live active-folder list, so any agent pulls the conventions before writing. Read-only. |
| `vault_sync(message?)` | Reconcile the vault with its git remote: commit local changes, `pull --rebase --autostash`, push. Pulls in writes other agents made via the GitHub API (and indexes them), publishes local writes. Fixed git sequence only, never a shell. Aborts cleanly on conflict. |
| `vault_get(path, offset?)` | Fetch a card; large files are byte-windowed. |
| `vault_status()` | Snapshot: layout, live counts (cards/folder + totals, inbox, messages), index freshness, and embedding backend + whether the model is warm. |
| `vault_list(kind)` | List canonical cards of a kind. |
| `vault_write(kind, title, content, tags?, links?)` | Persist a new fact to `inbox/`; triggers a debounced raw reindex (searchable in ~10s). |
| `vault_patch(path, append?, set_fields?)` | Atomically update an existing card: append text to the body (append-only) and/or set frontmatter fields (validated keys/values; `created` preserved, `updated` auto-bumped). Write-locked + atomic. For run logs, status/field updates. |
| `vault_promote(path, kind, title?)` | Move a raw inbox card into a canonical folder with cleaned frontmatter; triggers a full reindex. |

## Security

Bearer auth (constant-time) on all traffic including SSE; per-IP rate limit (CF-Connecting-IP); request body cap; path sandbox confined to the vault; secret redaction on snippets/titles/queries/audit; DNS-rebinding host validation disabled (required for tunnel ingress). Token lives in `<app-dir>/.token` (mode 600), never in the repo.

## Git sync (two write paths, one source of truth)

The vault is a git checkout of your own private repo (e.g. `you/poke-vault`). Two things write to it: the MCP tools (directly, on this Mac) and any agent with GitHub API access (commits straight to the repo, e.g. from a sandbox with no local git). `vault_sync` is the reconcile point: it commits local changes, `pull --rebase --autostash`es, and pushes, so both directions converge through git. When a pull brings new content it triggers a reindex so search reflects it.

It runs only a fixed git sequence (add / commit / pull / push), not a shell, so there's no arbitrary-command surface over the tunnel. On a merge conflict it runs `rebase --abort` and reports the conflict rather than guessing, leaving the working tree clean for manual resolution on the host. The subprocess PATH is augmented with the Homebrew prefixes so global git hooks (e.g. an LFS pre-push hook) resolve even under launchd's minimal PATH.

Auto-convergence (commit-on-write + a pull in the reindex cron) is intentionally deferred; sync is explicit for now. A general bash tool and additional MCPs are planned as a separate, isolated setup, not folded into this server.

## How background agents capture into the vault

The write surface (`vault_search`/`vault_list` to find, `vault_write` to capture, `vault_patch` to update) is meant to be frictionless for automations:

1. **Map to an existing project.** When an email or update arrives, `vault_search`/`vault_list` first to see if it belongs to a project/person you already track (e.g. quoxient, cadence). If so, it has a home.
2. **Capture raw.** Parse the details and `vault_write` a raw card into `inbox/`. To extend a live project or CRM card, `vault_patch` to append a dated log line or set a frontmatter field.
3. **Connect across sources.** Pull from anywhere (email, calendar, fitbit, chat) and land it in markdown so it becomes recallable. The vault is the source of truth.

The only timing to respect: a new raw write is searchable after the next reindex (~15-20s). For background agents that's invisible; don't write then immediately expect `vault_search` to find it in the same step (use the returned path with `vault_get` if you must read it back at once). Agents should call `vault_rules` first so they follow the voice and the map-before-create discipline.

## Reliability

- Searchers auto-reload when the on-disk `documents.index` mtime changes — no restart needed after reindex.
- Reindex runs under an OS advisory lock (`fcntl.flock`, non-blocking, via a Python self-re-exec) so the scheduled full build and write-triggered raw builds never run concurrently; the kernel releases it automatically if the holder dies (no stale-lock reclaim needed).
- Per-scope freshness: `reindex_stamp` (canonical/full) and `reindex_stamp_raw` are separate, so a raw-only reindex never reports canonical as freshly built. The stamp is written only when all build steps succeed; a `reindex_failed` marker is written otherwise, and `reindex.sh` exits nonzero on failure.
- When embeddings run on a remote OpenAI-compatible endpoint (openai mode), search has a cross-host dependency: if the endpoint is unreachable, `vault_search` returns a clean "backend unavailable, recall degraded" error rather than crashing — the vault stays intact. Local sentence-transformers has no such dependency.

## Install

### Prerequisites & permissions (macOS)

- **python3** (the installer builds a venv).
- **Ingress** (Poke needs a public HTTPS URL): `cloudflared` + a Cloudflare account/domain (named or API-token tunnel), **or** `ngrok` + an authtoken, **or** a Cloudflare quick tunnel (no account, ephemeral URL). Named-mode also needs a one-time `cloudflared tunnel login` (browser).
- **Message ingest (optional, on by default):** the `imsg` CLI (`brew install imsg`) plus **Full Disk Access**. launchd jobs do **not** inherit Full Disk Access, so for the scheduled daily ingest to read the Messages database you must add the venv python to it:
  1. System Settings, Privacy & Security, **Full Disk Access**
  2. Click **+**, then in the file picker press **Cmd+Shift+G** (the `.venv` path is hidden, so the picker will not show it otherwise)
  3. Paste `<app-dir>/.venv/bin/python`, select it, and toggle it on

  Until granted, the scheduled job fails (and `poke-vault doctor` flags it with this same fix). Manual `poke-vault ingest` from a terminal that already has Full Disk Access works regardless.
- **`vault_sync` (optional):** `git` + a **private** repo for the vault (it holds personal data).
- After install, register with Poke: `npx poke@latest mcp add https://<host>/mcp -k "$(cat <app-dir>/.token)"` (the installer prints the exact command; `poke-vault reconnect` reprints it later).

### The guided way

```bash
./install.sh
```

It checks prerequisites, detects ollama, prompts for paths, embeddings (local sentence-transformers by default, or any OpenAI-compatible endpoint), and ingress (Cloudflare named tunnel, ngrok, Cloudflare quick tunnel, or private/Tailscale), generates a token, builds the index, loads the launchd services, and prints the `npx poke mcp add ...` command.

**Embeddings.** Local sentence-transformers works offline with no API and is the default. For a faster/shared embedder, point at any OpenAI-compatible endpoint (ollama, OpenAI, an internal server).

**Ingress.** Poke is a cloud service, so it needs a stable public HTTPS URL. Options: a Cloudflare named tunnel via **browser login** (interactive, stable URL); a Cloudflare named tunnel via **API token** (no browser, agent-friendly — creates the tunnel, ingress config, and DNS over the CF API); **ngrok**; a Cloudflare **quick tunnel** (ephemeral URL); or **Tailscale/localhost** (private, only reachable on your own network).

### Managing it (the `poke-vault` CLI)

The installer puts a `poke-vault` command on your PATH:

```
poke-vault status      # are the services up, is the endpoint answering, is the index fresh
poke-vault doctor      # deeper checks: deps, embeddings, token, git sync, public URL
poke-vault sync [msg]  # reconcile the vault with its git remote (wraps vault_sync)
poke-vault reindex     # rebuild the index now
poke-vault logs [mcp|err|reindex]
poke-vault rules [--edit]   # view/edit the voice + operating-procedure docs agents follow
poke-vault uninstall   # remove services + CLI (your vault is never touched)
```

### Customizing the rules agents follow

`vault_rules` serves whatever is in `<vault>/docs/vault-operating-procedure.md`, `<vault>/docs/voice.md`, and `<vault>/docs/onboarding-playbook.md` (plus a live active-folder list). The installer seeds editable templates only if those files are absent, so your own versions are preserved. Edit them (or `poke-vault rules --edit`) to set your voice, write conventions, and cold-start behavior; point `POKE_RULES_DOCS` at different files to override entirely.

### Agent / non-interactive install

`install.sh` is interactive. To let an automation install it, write `deploy/.env` (see `.env.example`) and run `deploy/setup.sh` — `setup.sh` reads nothing from the terminal. For ingress, set `INGRESS=cfapi` with `CF_API_TOKEN`, `CF_ACCOUNT_ID`, and `CF_HOSTNAME`: the tunnel, ingress config, and DNS are created entirely over the Cloudflare API (no browser login, the one step an agent otherwise can't do). `INGRESS=quick` (ephemeral URL) and ngrok-with-authtoken are also agent-runnable.

### Advanced (non-interactive)

```bash
cd deploy
cp .env.example .env        # edit paths, embeddings, INGRESS, and (for a named tunnel) the CF_* values
./setup.sh                  # venv + deps, render configs, build index, load services
```

For a Cloudflare named tunnel: `cloudflared tunnel login`, then `cloudflared tunnel create <name>`, and set the resulting id/name/hostname in `.env`. If the hostname is in a zone not covered by your `~/.cloudflared/cert.pem`, create the proxied CNAME (`<hostname> → <tunnel-id>.cfargotunnel.com`) via the Cloudflare DNS API instead of `tunnel route dns`.

## Maintenance

```bash
.venv/bin/python lint.py    # missing frontmatter, orphans (no inbound [[link]]), dup titles, inbox backlog
```
