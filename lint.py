import os
import re
import sys
import datetime
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vault_manifest

VAULT = Path(os.environ.get("POKE_VAULT_ROOT", str(Path.home() / "poke-vault"))).resolve()
CANON = vault_manifest.canon_dirs(VAULT)
REQUIRED = ["title", "entity_type", "status"]
STALE_AFTER = 3600


def fm_body(path):
    lines = path.read_text(errors="replace").split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, "\n".join(lines)
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None:
        return {}, "\n".join(lines)
    try:
        m = yaml.safe_load("\n".join(lines[1:end])) or {}
    except Exception:
        m = {}
    return (m if isinstance(m, dict) else {}), "\n".join(lines[end + 1:])


def main():
    cards = []
    for kind in CANON:
        d = VAULT / kind
        if d.exists():
            cards += list(d.glob("*.md"))

    missing, titles, all_links, all_text = [], {}, set(), {}
    for p in cards:
        m, body = fm_body(p)
        rel = str(p.relative_to(VAULT))
        for f in REQUIRED:
            if not m.get(f):
                missing.append(f"{rel}: missing '{f}'")
        titles.setdefault(m.get("title", p.stem), []).append(rel)
        all_text[rel] = body + str(m.get("relations", ""))
        for link in re.findall(r"\[\[([a-z0-9-]+)\]\]", body + str(m.get("relations", ""))):
            all_links.add(link)

    orphans = []
    for p in cards:
        slug = p.stem
        rel = str(p.relative_to(VAULT))
        inbound = any(slug in re.findall(r"\[\[([a-z0-9-]+)\]\]", t) for r, t in all_text.items() if r != rel)
        if not inbound:
            orphans.append(rel)

    dupes = {t: rs for t, rs in titles.items() if len(rs) > 1}

    stamp = VAULT / ".vault" / "reindex_stamp"
    stale = "unknown"
    if stamp.exists():
        try:
            ts = datetime.datetime.fromisoformat(stamp.read_text().strip())
            age = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()
            stale = f"{int(age)}s ago ({'STALE' if age > STALE_AFTER else 'fresh'})"
        except Exception:
            pass

    print(f"=== lint: {len(cards)} canonical cards ===")
    print(f"index freshness: {stale}")
    print(f"\nmissing frontmatter ({len(missing)}):")
    for x in missing[:40]:
        print("  " + x)
    print(f"\norphans — no inbound [[link]] ({len(orphans)}):")
    for x in orphans[:40]:
        print("  " + x)
    print(f"\nduplicate titles ({len(dupes)}):")
    for t, rs in list(dupes.items())[:20]:
        print(f"  '{t}': {', '.join(rs)}")
    inbox = list((VAULT / "inbox").glob("*.md")) if (VAULT / "inbox").exists() else []
    print(f"\ninbox backlog (promotion decay risk): {len(inbox)} raw cards")


if __name__ == "__main__":
    main()
