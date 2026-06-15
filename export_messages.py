import os
import re
import sys
import json
import hashlib
import datetime
import subprocess
import collections
from pathlib import Path

VAULT = Path(os.environ.get("POKE_VAULT_ROOT", str(Path.home() / "poke-vault"))).resolve()
OUT = VAULT / "inbox" / "messages"
POKE_NUMBERS = {re.sub(r"[^0-9]", "", n) for n in os.environ.get("POKE_NUMBERS", "").split(",") if n}
POKE_IDENTIFIERS = {s.strip() for s in os.environ.get("POKE_IDENTIFIERS", "").split(",") if s.strip()}
NAME_RX = re.compile(os.environ.get("POKE_NAME_REGEX", r"^poke$"), re.I)
MONTH_RX = re.compile(r"^\d{4}-\d{2}")
MONTH_FILE_RX = re.compile(r"^poke-\d{4}-\d{2}\.(md|jsonl)$")


def warn(msg):
    print(f"[export_messages] {msg}", file=sys.stderr)


def imsg(args):
    proc = subprocess.run(["imsg", *args, "--json"], capture_output=True, text=True)
    if proc.returncode != 0:
        warn(f"imsg {' '.join(args)} failed (rc={proc.returncode}): {proc.stderr.strip()[:300]}")
        raise RuntimeError(f"imsg {args[0]} failed")
    rows = []
    dec = json.JSONDecoder(strict=False)
    s = proc.stdout
    i, n, skipped = 0, len(s), 0
    while i < n:
        while i < n and s[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        try:
            obj, end = dec.raw_decode(s, i)
            rows.append(obj)
            i = end
        except json.JSONDecodeError:
            nl = s.find("\n", i)
            if nl == -1:
                break
            i = nl + 1
            skipped += 1
    if skipped:
        warn(f"recovered past {skipped} malformed span(s) in imsg output")
    return rows


def is_poke_chat(c):
    name = str(c.get("name") or "").strip()
    ident = str(c.get("identifier") or "")
    if NAME_RX.search(name):
        return True
    if ident in POKE_IDENTIFIERS:
        return True
    digits = re.sub(r"[^0-9]", "", ident)
    return bool(digits) and any(digits.endswith(n) for n in POKE_NUMBERS if n)


def norm(m):
    return {
        "created_at": str(m.get("created_at") or m.get("date") or ""),
        "is_from_me": bool(m.get("is_from_me")),
        "sender": str(m.get("sender") or ""),
        "text": (m.get("text") or "").strip(),
        "guid": str(m.get("guid") or ""),
    }


def dedup_key(r):
    if r["guid"]:
        return r["guid"]
    h = hashlib.sha1(r["text"].encode("utf-8", "ignore")).hexdigest()
    return f"{r['created_at']}|{r['sender']}|{h}"


def collect():
    by_key = {}
    chats = imsg(["chats"])
    matched = [c for c in chats if is_poke_chat(c)]
    if not matched:
        warn("no Poke chats matched. Set POKE_NAME_REGEX / POKE_NUMBERS / POKE_IDENTIFIERS to your thread.")
    for c in matched:
        warn(f"matched chat: id={c.get('id') or c.get('chat_id')} name={c.get('name')!r} ident={c.get('identifier')}")
    for c in matched:
        cid = c.get("id") or c.get("chat_id")
        if cid is None:
            continue
        for m in imsg(["history", "--chat-id", str(cid), "--limit", "100000"]):
            r = norm(m)
            if r["text"]:
                by_key[dedup_key(r)] = r
    for arc in (VAULT / "inbox").rglob("*archive*.json"):
        try:
            data = json.loads(arc.read_text())
        except Exception as e:
            warn(f"skipped unreadable archive {arc.name}: {e}")
            continue
        for m in (data if isinstance(data, list) else []):
            r = norm(m)
            if r["text"]:
                by_key[dedup_key(r)] = r
    good, bad = [], 0
    for r in by_key.values():
        if MONTH_RX.match(r["created_at"]):
            good.append(r)
        else:
            bad += 1
    if bad:
        warn(f"{bad} messages skipped for malformed/missing created_at")
    return good, len(matched)


def speaker(r):
    return "Me" if r["is_from_me"] else "Poke"


def day_doc(day, rows):
    fm = [
        "---",
        f"title: Poke conversation {day}",
        "entity_type: messages",
        "source_type: imessage",
        "participant: poke",
        f"date: {day}",
        f"count: {len(rows)}",
        "status: raw",
        "---",
        "",
        f"# Poke conversation {day}",
        "",
    ]
    body = [f"**{r['created_at'][:10]} {r['created_at'][11:16]} {speaker(r)}:** {r['text']}" for r in rows]
    return "\n".join(fm + body) + "\n"


def _atomic_write(path, text):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def write_days(days, today, out=OUT):
    # Skip a closed day only when both md and jsonl match byte-for-byte (content, not mere
    # existence); that exact-match skip is what keeps the HNSW reindex incremental, so don't
    # weaken it. Writes are atomic so a partial/stale sidecar can't be mistaken for current.
    out.mkdir(parents=True, exist_ok=True)
    written = unchanged = deferred = 0
    for day, rows in sorted(days.items()):
        if day >= today:
            deferred += 1
            continue
        md = out / f"poke-{day}.md"
        jsonl = out / f"poke-{day}.jsonl"
        new_md = day_doc(day, rows)
        new_jsonl = "".join(json.dumps(r) + "\n" for r in rows)
        try:
            if md.exists() and jsonl.exists() and md.read_text() == new_md and jsonl.read_text() == new_jsonl:
                unchanged += 1
                continue
        except OSError:
            pass
        _atomic_write(jsonl, new_jsonl)
        _atomic_write(md, new_md)
        written += 1
    return written, unchanged, deferred


def cleanup_month_files(out=OUT):
    removed = 0
    if not out.exists():
        return 0
    for p in out.iterdir():
        if p.is_file() and MONTH_FILE_RX.match(p.name):
            try:
                p.unlink()
                removed += 1
            except OSError as e:
                warn(f"could not remove stale month file {p.name}: {e}")
    return removed


def main():
    msgs, n_chats = collect()
    msgs.sort(key=lambda r: (r["created_at"], r["guid"], r["sender"], r["text"]))
    days = collections.defaultdict(list)
    for r in msgs:
        days[r["created_at"][:10]].append(r)
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    written, unchanged, deferred = write_days(days, today)
    removed = cleanup_month_files()
    print(f"chats matched: {n_chats}  messages: {len(msgs)}  days: {len(days)}  "
          f"written: {written}  unchanged: {unchanged}  deferred(>=today): {deferred}  month-files-removed: {removed}")


if __name__ == "__main__":
    main()
