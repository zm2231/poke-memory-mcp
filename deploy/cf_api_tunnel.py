import json
import os
import sys
import urllib.request
import urllib.error

API = "https://api.cloudflare.com/client/v4"


def _req(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            payload = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode())
        except Exception:
            payload = {"success": False, "errors": [{"message": f"HTTP {e.code}"}]}
    if not payload.get("success", False):
        msg = "; ".join(str(x.get("message", x)) for x in payload.get("errors", [])) or "unknown error"
        raise SystemExit(f"cloudflare api error on {method} {path}: {msg}")
    return payload.get("result")


def resolve_zone(token, hostname):
    labels = hostname.split(".")
    for i in range(len(labels) - 1):
        candidate = ".".join(labels[i:])
        res = _req("GET", f"/zones?name={candidate}", token)
        if res:
            return res[0]["id"]
    raise SystemExit(f"no Cloudflare zone found for {hostname}; is the domain on this account?")


def find_or_create_tunnel(token, account, name):
    res = _req("GET", f"/accounts/{account}/cfd_tunnel?name={name}&is_deleted=false", token)
    if res:
        return res[0]["id"]
    created = _req("POST", f"/accounts/{account}/cfd_tunnel", token,
                   {"name": name, "config_src": "cloudflare"})
    return created["id"]


def tunnel_token(token, account, tunnel_id):
    return _req("GET", f"/accounts/{account}/cfd_tunnel/{tunnel_id}/token", token)


def put_ingress(token, account, tunnel_id, hostname, port):
    cfg = {"config": {"ingress": [
        {"hostname": hostname, "service": f"http://127.0.0.1:{port}"},
        {"service": "http_status:404"},
    ]}}
    _req("PUT", f"/accounts/{account}/cfd_tunnel/{tunnel_id}/configurations", token, cfg)


def upsert_cname(token, zone, hostname, target):
    existing = _req("GET", f"/zones/{zone}/dns_records?name={hostname}&type=CNAME", token)
    body = {"type": "CNAME", "name": hostname, "content": target, "proxied": True}
    if existing:
        _req("PUT", f"/zones/{zone}/dns_records/{existing[0]['id']}", token, body)
    else:
        _req("POST", f"/zones/{zone}/dns_records", token, body)


def main():
    token = os.environ.get("CF_API_TOKEN", "")
    account = os.environ.get("CF_ACCOUNT_ID", "")
    hostname = os.environ.get("CF_HOSTNAME", "")
    name = os.environ.get("CF_TUNNEL_NAME", "poke-memory")
    port = os.environ.get("POKE_VAULT_PORT", "8077")
    token_out = os.environ.get("CF_TOKEN_OUT", "")
    for k, v in [("CF_API_TOKEN", token), ("CF_ACCOUNT_ID", account), ("CF_HOSTNAME", hostname), ("CF_TOKEN_OUT", token_out)]:
        if not v:
            raise SystemExit(f"{k} is required")
    zone = resolve_zone(token, hostname)
    tid = find_or_create_tunnel(token, account, name)
    put_ingress(token, account, tid, hostname, port)
    upsert_cname(token, zone, hostname, f"{tid}.cfargotunnel.com")
    conn_token = tunnel_token(token, account, tid)
    fd = os.open(token_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(conn_token)
    print(json.dumps({"tunnel_id": tid, "hostname": hostname, "zone": zone}))


if __name__ == "__main__":
    main()
