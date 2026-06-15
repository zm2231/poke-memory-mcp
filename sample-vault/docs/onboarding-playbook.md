# Onboarding Playbook (cold start)

version: 1

The conditional, time-boxed procedure for when the vault is new and the owner is still unknown. The always-on rules live in `vault-operating-procedure.md` (how/where to write), `voice.md` (how to write), and the live "Active folders" block in `vault_rules` (which folders exist + their triggers, and the propose/register/reject flow). This doc only adds the cold-start behavior; it does not restate those.

## When this applies
Read `people/owner.md` first (it ships seeded). Follow this doc only while it reads `onboarding_status: new`. Once you have learned the owner's basics, set `onboarding_status: established` and stop following this doc - operate under the normal VOP. A missing owner card means an existing vault; treat it as established and do not re-onboard.

## Principle: deduce, don't interrogate (but don't stall either)
Learn the owner from what they actually say and ask you to do, not a day-one questionnaire. But a new vault has nothing to deduce from, so on first contact do a light touch: confirm you can remember things for them and ask at most one or two open questions ("what should I keep track of for you?"). Then mostly listen and capture.

## The owner card is your only memory between conversations
You retain nothing across conversations except what is written to the vault, so `people/owner.md` is where onboarding state lives. It is seeded at install - do not create it; just keep it current with `vault_patch`, and READ it at the start of each session to recover what you already know.
- `set_fields` holds only scalars / lists of plain strings. Use it for flat summary fields: `preferred_name`, `onboarding_status` (new|established), `roles` (list of strings), `last_seen`.
- Everything with structure - observed patterns (a recurring topic, how many times, an example, when last seen) and proposed folders (the slug, the ask, pending/accepted/rejected) - goes as dated lines you `append` to the card body under its "Observed patterns" and "Proposed folders" sections. (Frontmatter cannot hold lists of objects; they are silently dropped.)

## Signals you may actually use
Only these. Do not claim to watch accounts, inboxes, or activity you were not given.
- The current conversation (what the owner says and asks you to do).
- Explicit owner intent ("help me track my assignments / meetings / recipes").
- Vault contents (`vault_search`, `vault_query`, `vault_list`, `vault_status`) - e.g. several inbox cards clustering on one topic.
- What you wrote on `people/owner.md` in past sessions (observed patterns, pending proposals).
- Integration data ONLY if a recipe or the current session actually hands it to you. If you do not have it, do not infer from it.

## Proposing a folder
The propose/register/reject flow and the current folder set are in the `vault_rules` Active-folders block - follow it. Cold-start only adds the threshold: do NOT propose from a single mention. Propose one folder, when justified by either an explicit request to track a recurring category, or 3+ separate captures over several days clustering on it (which you can only know by reading the patterns you appended to `people/owner.md`). On silence, record it as pending in the body and move on; revisit only if evidence keeps growing.

## First week
- Day 0: read `people/owner.md`; do the light-touch intro; record the owner's name/preference with `set_fields`.
- Days 1-3: capture useful durable facts to `inbox`; append durable learnings and observed patterns to the owner card; do not propose folders unless explicitly asked.
- Days 3-7: if real clusters emerge from actual conversations, propose at most one folder.
- When the owner's basics are captured, set `onboarding_status: established`.
- Always: write observations and proposals back to the owner card so your future self can act on them.

## If something is missing
- No integrations / empty vault / no signal yet: just capture what the owner tells you and keep the owner card current. That is success for week one.
- Unsure whether a fact is durable: put it in `inbox` (raw-first); promote later.
- To confirm a write landed, read it back with `vault_get` on the path the write returned - a new write is not searchable for ~15-20s.
