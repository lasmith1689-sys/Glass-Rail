#!/usr/bin/env python3
"""Shape of NJ Transit's red notes and rail travel alerts."""
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
Q = {
 "red.notice": "{ getRedNotes { notice } }",
 "red.notice.sub": "{ getRedNotes { notice { zzzz } } }",
 "red.lines-str": '{ getRedNotes(lines: "MOBO") { notice } }',
 "red.lines-list": '{ getRedNotes(lines: ["MOBO"]) { notice } }',
 "red.lines-bntn": '{ getRedNotes(lines: ["BNTN"]) { notice } }',
 "red.lines-name": '{ getRedNotes(lines: ["Montclair-Boonton Line"]) { notice } }',
 "red.lines-rail": '{ getRedNotes(lines: ["RAIL"]) { notice } }',
 "travel": "{ getRailAlertsAdvisories { travelAlerts } }",
 "travel.sub": "{ getRailAlertsAdvisories { travelAlerts { zzzz } } }",
}
for g in ["id", "title", "text", "message", "description", "body", "header", "line", "lines", "lineCode", "lineName", "url", "link", "date", "dates", "createdAt", "startDate", "endDate", "type", "mode", "noticeType", "noticeText", "severity", "agency", "route", "routes", "advisories", "alerts", "name", "summary", "station", "stations", "content", "details"]:
    Q["red." + g] = "{ getRedNotes { %s } }" % g
    Q["travel." + g] = "{ getRailAlertsAdvisories { travelAlerts { %s } } }" % g
    Q["aa." + g] = "{ getRailAlertsAdvisories { %s } }" % g
res = {}
with ThreadPoolExecutor(8) as ex:
    for (n, q), (s, p) in zip(Q.items(), ex.map(lambda q: post(q), Q.values())):
        errs = [e.get("message", "")[:240] for e in (p.get("errors") or []) if isinstance(e, dict)]
        res[n] = {"status": s, "errors": errs, "data": json.dumps(p.get("data"))[:3000] if p.get("data") is not None else None}
json.dump(res, open(os.path.join(OUT, "results.json"), "w"), indent=1)
lines = ["# Red notes and travel alerts\n"]
for n, v in res.items():
    if v["data"] and v["data"] != "null" and "null}" not in v["data"][:60] or any("Did you mean" in e or "selection" in e or "argument" in e.lower() for e in v["errors"]):
        lines.append(f"- {n}: {v['status']} | {' / '.join(v['errors'][:2])} | {(v['data'] or '')[:1500]}")
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))
