# Voice & Write Playbook

This is a starting template. Replace it with your own voice and conventions. Any agent writing to the vault pulls this via `vault_rules` before calling `vault_write`, `vault_patch`, or `vault_promote`.

## Voice

- Plain, factual, concise. State the thing; do not perform.
- Separate fact from hypothesis. Label anything unverified; never let a guess land as flat fact.
- Cite provenance. When a card states something, point at where it came from (a date, a source, a message) so it can be traced.
- (Optional, a common preference) avoid em dashes; use periods or commas.

## Write playbook

1. **Map before you create.** Run `vault_search` or `vault_list` first to find an existing project or person card. If a match exists, update it. Do not spawn a duplicate.
2. **Capture raw to inbox.** Parse the details and `vault_write` a raw card into `inbox/`. Preserve source fidelity.
3. **Update live cards surgically.** Extend an existing card with `vault_patch`: append a dated log line, or set a frontmatter field (status, stage, last_contact). The body is append-only.
4. **Vault is king.** Pull from any source (email, calendar, chat, metrics) and land it in markdown so it becomes recallable.

## Raw-first stance

Recall value comes from rich raw context plus good search, not a hand-tended wiki. Lead with ingestion and retrieval. Treat `vault_promote` (inbox to canonical) as optional cleanup, not the main loop. Do not block a capture on deciding where it should eventually live.

## Indexing lag

A new raw write is searchable after the next reindex (roughly 15 to 20 seconds). For a background agent this is invisible. Do not write a card and immediately expect `vault_search` to return it in the same step; use `vault_get` on the returned path if you must read it back at once.

## Grounding

Check the vault before relying on memory. Use it to resolve ambiguity and avoid drift. Write durable new information back.
