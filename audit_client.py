import asyncio
import os
import json
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

URL = "http://127.0.0.1:8077/mcp"
TOKEN = open(os.path.expanduser("~/poke-memory/.token")).read().strip()


async def call(session, name, args):
    try:
        res = await session.call_tool(name, args)
        txt = "".join(getattr(c, "text", "") for c in res.content)
        return txt[:500]
    except Exception as e:
        return f"ERROR: {type(e).__name__}: {e}"


async def main():
    headers = {"Authorization": f"Bearer {TOKEN}"}
    async with streamablehttp_client(URL, headers=headers) as (r, w, _):
        async with ClientSession(r, w) as session:
            await session.initialize()
            tools = await session.list_tools()
            print("TOOLS:", [t.name for t in tools.tools])
            print("\n[search mercury]:", (await call(session, "vault_search", {"query": "forwarding receipts to mercury", "limit": 1}))[:240])
            print("\n[search hybrid vw=0.2]:", (await call(session, "vault_search", {"query": "lifestance", "vector_weight": 0.2, "limit": 1}))[:160])
            print("\n[search bad vw]:", (await call(session, "vault_search", {"query": "x", "vector_weight": "bad", "limit": 1}))[:120])
            print("\n[multi]:", (await call(session, "vault_search_multi", {"queries": [{"query": "joycat", "vector_weight": 0.2}, {"query": "receipts"}, {"bad": "item"}]}))[:200])
            print("\n[multi bad input]:", await call(session, "vault_search_multi", {"queries": "notalist"}))
            print("\n[warm]:", await call(session, "vault_warm", {}))
            print("\n[search_messages exact]:", (await call(session, "vault_search_messages", {"query": "lifestance", "limit": 1, "context": 1}))[:240])
            print("\n[search_messages filters]:", (await call(session, "vault_search_messages", {"sender": "me", "date_from": "2025-11-01", "date_to": "2025-11-30", "limit": 1, "context": 0}))[:160])
            print("\n[search_messages bad limit]:", (await call(session, "vault_search_messages", {"query": "x", "limit": "abc"}))[:120])
            print("\n[search_messages huge limit/context clamp]:", (await call(session, "vault_search_messages", {"query": "the", "limit": 999, "context": 999}))[:120])
            print("\n[search_messages bad context]:", (await call(session, "vault_search_messages", {"query": "x", "context": "abc"}))[:120])
            print("\n[search_messages empty browse]:", (await call(session, "vault_search_messages", {"limit": 2, "context": 0}))[:120])
            print("\n[search_messages odd date/sender]:", (await call(session, "vault_search_messages", {"sender": "nobody", "date_from": "not-a-date", "limit": 1}))[:120])
            print("\n[related by path]:", (await call(session, "vault_related", {"path": "projects/mercury-automation.md", "limit": 3}))[:200])
            print("\n[related by query]:", (await call(session, "vault_related", {"query": "receipt automation", "scope": "all", "limit": 2}))[:160])
            print("\n[related neither]:", await call(session, "vault_related", {}))
            print("\n[verify true claim]:", (await call(session, "vault_verify", {"claim": "The Mercury automation forwards receipts through Cadence", "scope": "canonical", "limit": 3}))[:200])
            print("\n[verify empty]:", await call(session, "vault_verify", {"claim": "  "}))
            print("\n[query status exists]:", (await call(session, "vault_query", {"where": [{"field": "status", "op": "exists"}], "sort": "updated", "order": "desc", "limit": 2}))[:200])
            print("\n[query contains]:", (await call(session, "vault_query", {"where": [{"field": "tags", "op": "contains", "value": "security"}], "limit": 2}))[:160])
            print("\n[query bad op]:", await call(session, "vault_query", {"where": [{"field": "x", "op": "DROP", "value": "y"}]}))
            print("\n[query missing field]:", await call(session, "vault_query", {"where": [{"op": "eq", "value": "y"}]}))
            print("\n[timeline]:", (await call(session, "vault_timeline", {"query": "mercury", "limit": 2}))[:200])
            print("\n[timeline empty query]:", await call(session, "vault_timeline", {"query": "  "}))
            print("\n[backlinks card]:", await call(session, "vault_backlinks", {"path": "people/paula.md"}))
            print("\n[backlinks no arg]:", await call(session, "vault_backlinks", {}))
            print("\n[patch nonexistent]:", await call(session, "vault_patch", {"path": "projects/nope-xyz.md", "append": "x"}))
            print("\n[patch outside]:", await call(session, "vault_patch", {"path": ".vault/x.md", "append": "x"}))
            print("\n[patch traversal]:", await call(session, "vault_patch", {"path": "../../../etc/passwd.md", "append": "x"}))
            print("\n[patch empty]:", await call(session, "vault_patch", {"path": "projects/mercury-automation.md"}))
            print("\n[traversal /etc/passwd]:", await call(session, "vault_get", {"path": "../../../../../../etc/passwd"}))
            print("\n[traversal ssh key]:", await call(session, "vault_get", {"path": "../../.ssh/id_rsa"}))
            print("\n[abs path]:", await call(session, "vault_get", {"path": "/etc/hosts"}))
            print("\n[valid get]:", (await call(session, "vault_get", {"path": "projects/mercury-automation.md"}))[:160])


asyncio.run(main())
