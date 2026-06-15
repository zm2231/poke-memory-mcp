import os
import tempfile

os.environ.setdefault("POKE_VAULT_ROOT", tempfile.mkdtemp())
os.environ.setdefault("POKE_VAULT_INDEX", "/tmp/poke-test-none/documents.leann")
os.environ.setdefault("POKE_VAULT_TOKEN", "test-token-not-real")

import vault_mcp as v

FAILED = []


def check(name, got, want):
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}: got {got!r} want {want!r}")
        FAILED.append(name)


def main():
    check("limit default", v._coerce_limit(None), 5)
    check("limit clamp hi=10", v._coerce_limit(999), 10)
    check("limit hi=20 reachable", v._coerce_limit(999, 10, 20), 20)
    check("limit bad string", v._coerce_limit("abc", 7, 20), 7)
    check("limit floor 1", v._coerce_limit(0), 1)
    check("limit negative", v._coerce_limit(-5), 1)

    check("vw sentinel -1 -> default", v._coerce_vw(-1.0), v.DEFAULT_VECTOR_WEIGHT)
    check("vw clamp high", v._coerce_vw(5.0), 1.0)
    check("vw clamp low", v._coerce_vw(-0.0), 0.0)
    check("vw bad string -> default", v._coerce_vw("x"), v.DEFAULT_VECTOR_WEIGHT)
    check("vw None -> default", v._coerce_vw(None), v.DEFAULT_VECTOR_WEIGHT)
    check("vw mid passthrough", v._coerce_vw(0.3), 0.3)

    check("iso full timestamp", v._iso_date("2026-05-01T12:00:00Z"), "2026-05-01")
    check("iso date only", v._iso_date("2026-05-01"), "2026-05-01")
    check("iso garbage 'soon'", v._iso_date("soon"), "")
    check("iso garbage 'unknown'", v._iso_date("unknown"), "")
    check("iso None", v._iso_date(None), "")
    check("iso partial YYYY-MM", v._iso_date("2026-05"), "")
    check("iso non-str", v._iso_date(20260501), "")

    check("eqv numeric", v._eqv(3, "3"), True)
    check("eqv str ci", v._eqv("Done", "done"), True)
    check("eqv ne", v._eqv("a", "b"), False)
    m = {"status": "blocked", "stage": "proposal", "tags": ["project", "crm"], "score": 7, "updated": "2026-05-01"}
    check("cond eq", v._match_cond(m, {"field": "status", "op": "eq", "value": "blocked"}), True)
    check("cond ne", v._match_cond(m, {"field": "status", "op": "ne", "value": "done"}), True)
    check("cond contains list", v._match_cond(m, {"field": "tags", "op": "contains", "value": "crm"}), True)
    check("cond contains miss", v._match_cond(m, {"field": "tags", "op": "contains", "value": "zzz"}), False)
    check("cond in", v._match_cond(m, {"field": "stage", "op": "in", "value": ["proposal", "closed"]}), True)
    check("cond exists", v._match_cond(m, {"field": "stage", "op": "exists"}), True)
    check("cond missing true", v._match_cond(m, {"field": "nope", "op": "missing"}), True)
    check("cond gt numeric", v._match_cond(m, {"field": "score", "op": "gt", "value": 5}), True)
    check("cond lt date", v._match_cond(m, {"field": "updated", "op": "lt", "value": "2026-06-01"}), True)
    check("cond bad op", v._match_cond(m, {"field": "status", "op": "DROP", "value": "x"}), False)
    check("cond gt list -> false", v._match_cond({"x": [1, 2]}, {"field": "x", "op": "gt", "value": 5}), False)
    check("cond lt None -> false", v._match_cond({"x": None}, {"field": "x", "op": "lt", "value": "2026-01-01"}), False)
    check("cond absent field eq", v._match_cond(m, {"field": "nope", "op": "eq", "value": "x"}), False)

    ev = [{"path": "projects/a.md", "snippet": "x"}, {"path": "people/b.md", "snippet": "y"}]
    good = v._parse_judge('{"verdict":"supported","confidence":0.8,"reasoning":"r","supporting":[1],"contradicting":[]}', ev)
    check("judge verdict", good and good["verdict"], "supported")
    check("judge cite map", good and good["supporting"], ["projects/a.md"])
    check("judge in prose", (v._parse_judge('sure! {"verdict":"contradicted","confidence":1}  done', ev) or {}).get("verdict"), "contradicted")
    check("judge non-json", v._parse_judge("no json here", ev), None)
    check("judge bad verdict", v._parse_judge('{"verdict":"maybe"}', ev), None)
    check("judge conf clamp", (v._parse_judge('{"verdict":"supported","confidence":5}', ev) or {}).get("confidence"), 1.0)
    check("judge conf bad->0", (v._parse_judge('{"verdict":"supported","confidence":"hi"}', ev) or {}).get("confidence"), 0.0)
    check("judge cite oob filtered", (v._parse_judge('{"verdict":"supported","supporting":[1,9,"x"]}', ev) or {}).get("supporting"), ["projects/a.md"])
    check("judge cite not-list", (v._parse_judge('{"verdict":"supported","supporting":"1"}', ev) or {}).get("supporting"), [])

    check("tagset list", v._tagset(["A", "b"]), {"a", "b"})
    check("tagset scalar str (not chars)", v._tagset("alpha"), {"alpha"})
    check("tagset int no crash", v._tagset(123), {"123"})
    check("tagset None", v._tagset(None), set())
    check("tagset dict", v._tagset({"a": 1}), set())
    check("tagset bool", v._tagset(True), set())
    check("tagset mixed filtered", v._tagset(["x", None, True, 7]), {"x", "7"})

    if FAILED:
        raise SystemExit(f"\n{len(FAILED)} test(s) FAILED: {FAILED}")
    print("\nALL HELPER TESTS PASSED")


if __name__ == "__main__":
    main()
