# Vault Operating Procedure (VOP)

This is a starting template. Edit it to fit how you work. Any agent writing to the vault should pull this (and `docs/voice.md`) via the `vault_rules` tool before writing.

## 0. Cold start
Read `people/owner.md` first. If it reads `onboarding_status: new`, follow `docs/onboarding-playbook.md` for the cold-start period instead of assuming an established vault. Once the owner's basics are captured, set `onboarding_status: established` and operate under the rules below. (Treat a missing owner card as established - do not re-onboard an existing vault.)

## 1. Ingest
Raw observations, session summaries, transcripts, and updates land in `/inbox` first.

- Preserve source fidelity; record enough context to refactor later.
- Do not prematurely canonicalize incoming material.

## 2. Refactor
Periodically promote durable raw notes into canonical cards under the active entity folders (always `/projects` and `/people`; plus any others the owner has enabled).

- Canonical cards use Markdown with YAML frontmatter.
- Deduplicate before promotion; prefer stable names and durable cross-links.
- Promotion is optional cleanup, not a required step (see the raw-first note in `docs/voice.md`).

## 2a. Folders are dynamic
The active folder set is whatever `vault_rules` / `vault_status` report. Write only to those folders. Raw by default, canonical by exception.

- A decision, event, topic, or source is metadata that belongs **inside** the relevant project or person card, not in its own folder.
- If a recurring category genuinely needs its own folder (e.g. the owner asks to track assignments, meetings, recipes), propose it to the owner in plain language. On an explicit yes, call `vault_register_folder(name, trigger)`. On an explicit no, call `vault_reject_folder(name)` so it is never proposed again. On silence or a non-answer, do nothing (do not reject, do not nag).
- Never invent or write to a folder the owner has not approved.

## 3. Grounding
Treat the vault as the primary source of truth for context and history.

- Check the vault before relying on memory or inference.
- Write new durable information back.

## 4. Maintenance
- Reindex on the appropriate cadence (a scheduled full reindex runs automatically).
- Eliminate stale duplicates; normalize structure.
- Do not overwrite authoritative content without review.

## 5. Scope
This procedure applies only within the configured vault root (`POKE_VAULT_ROOT`). Writes reach the vault only through the MCP tools (`vault_write`, `vault_patch`, `vault_promote`), which sandbox every path to this root.

## 6. Voice
See `docs/voice.md` for how to write into the vault. Pull both files via `vault_rules` before any write.
