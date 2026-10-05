#!/usr/bin/env python3
"""Find the fields of NJ Transit's alert queries through GraphQL suggestions and errors."""
import json, os, sys, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
URL = "https://www.njtransit.com/api/graphql/graphql"
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)
def post(q):
    req = urllib.request.Request(URL, data=json.dumps({"query": q, "variables": {}}).encode(), method="POST", headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}
def msgs(p):
    errs = p.get("errors") or ((p.get("data") or {}).get("errors") if isinstance(p.get("data"), dict) else None) or []
    return [e.get("message", "") for e in errs if isinstance(e, dict)]
GUESS = ["id", "title", "message", "text", "body", "description", "content", "summary", "subject", "header", "name", "type", "mode",
         "line", "lines", "route", "routes", "station", "stations", "startDate", "endDate", "start", "end", "date", "createdAt", "updatedAt",
         "url", "link", "severity", "priority", "category", "status", "active", "isActive", "agency", "alertType", "effect", "cause",
         "items", "alerts", "notes", "data", "results", "advisories", "rail", "bus", "lightRail", "railAlerts", "busAlerts"]
queries = {}
for root in ["getRedNotes", "getRailAlertsAdvisories", "getAdvisories", "getHomeBanner"]:
    queries[root + "-bare"] = "{ %s }" % root
    for g in GUESS:
        queries[f"{root}.{g}"] = "{ %s { %s } }" % (root, g)
    for arg in ["mode: \"RAIL\"", "mode: \"Rail\"", "type: \"RAIL\"", "line: \"MOBO\"", "station: \"Watchung Avenue\""]:
        queries[f"{root}({arg})"] = "{ %s(%s) { id } }" % (root, arg)
out = {}
with ThreadPoolExecutor(8) as ex:
    for (name, q), (s, p) in zip(queries.items(), ex.map(lambda q: post(q), queries.values())):
        out[name] = {"status": s, "messages": msgs(p), "data": (json.dumps(p.get("data"))[:1500] if isinstance(p, dict) and p.get("data") is not None else None)}
json.dump(out, open(os.path.join(OUT, "results.json"), "w"), indent=1)
lines = ["# Alert query discovery\n"]
for name, r in out.items():
    if r["data"] and r["data"] != "null" or any("Did you mean" in m or "argument" in m or "must have a selection" in m or "Expected" in m for m in r["messages"]):
        lines.append(f"- {name}: HTTP {r['status']} | {' / '.join(m[:220] for m in r['messages'][:2])} | data: {(r['data'] or '')[:700]}")
lines.append(f"\n{len(out)} queries.")
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))
