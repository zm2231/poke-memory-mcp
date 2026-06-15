import json
import re
from pathlib import Path

FOLDER_NAME_RX = re.compile(r"^[a-z][a-z0-9-]{0,63}$")

DEFAULT_FOLDERS = {
    "inbox": {
        "kind": "raw",
        "always": True,
        "desc": "raw captures and session logs before they are merged; new facts land here first",
        "trigger": "raw content from a conversation or import that is not an update to an existing standing card",
    },
    "projects": {
        "kind": "canonical",
        "always": True,
        "desc": "active work, clients, products",
        "trigger": "a named effort with goal, status, next steps, or blockers that will matter across multiple sessions",
    },
    "people": {
        "kind": "canonical",
        "always": True,
        "desc": "contacts, dossiers, relationship and interaction logs",
        "trigger": "someone whose facts change how Poke should recognize, prioritize, reply to, or relate to them later",
    },
}


def default_manifest():
    return {"version": 1, "folders": {k: dict(v) for k, v in DEFAULT_FOLDERS.items()},
            "integrations": {}, "rejected": []}


def normalize(data):
    if not isinstance(data, dict):
        data = {}
    folders = data.get("folders")
    if not isinstance(folders, dict):
        folders = {}
    clean = {}
    for name, spec in folders.items():
        if (isinstance(name, str) and FOLDER_NAME_RX.match(name)
                and isinstance(spec, dict) and spec.get("kind") in ("raw", "canonical")):
            clean[name] = spec
    for name, spec in DEFAULT_FOLDERS.items():
        if spec.get("always") and name not in clean:
            clean[name] = dict(spec)
    data["folders"] = clean
    if not isinstance(data.get("integrations"), dict):
        data["integrations"] = {}
    rej = data.get("rejected")
    data["rejected"] = [r for r in rej if isinstance(r, str)] if isinstance(rej, list) else []
    if not isinstance(data.get("version"), int):
        data["version"] = 1
    return data


def manifest_path(vault_root):
    return Path(vault_root) / ".vault" / "manifest.json"


def load_manifest(vault_root):
    try:
        data = json.loads(manifest_path(vault_root).read_text())
    except Exception:
        data = default_manifest()
    return normalize(data)


def canon_dirs(vault_root):
    m = load_manifest(vault_root)
    return [n for n, f in m["folders"].items() if isinstance(f, dict) and f.get("kind") == "canonical"]
