#!/usr/bin/env python3
"""Which rail alert group is which line: fields of AlertAdvisory, travel alerts and train lines."""
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
G = ["lineCode", "lineName", "lineId", "lineAbbreviation", "lineAbbr", "abbreviation", "abbr", "code", "slug", "shortName", "longName",
     "displayName", "routeLongName", "routeShortName", "routeId", "routeName", "routeCode", "color", "lineColor", "icon", "title", "label",
     "travelAdvisories", "plannedWork", "plannedWorks", "serviceAdvisories", "serviceAlerts", "delays", "elevatorOutages", "nid", "uuid",
     "lineInfo", "transitLine", "trainLine", "railLine", "lineTitle", "name", "id", "type", "key", "value", "updated", "tag", "tags",
     "category", "categories", "advisory", "alertsCount", "count", "total", "lineNumber", "number", "order", "weight", "sort"]
Q = {"lines": "{ getTrainLines { zzzz } }", "lines-bare": "{ getTrainLines }"}
for g in G:
    Q["aa." + g] = "{ getRailAlertsAdvisories { %s } }" % g
    Q["tl." + g] = "{ getTrainLines { %s } }" % g
    Q["ta." + g] = "{ getRailAlertsAdvisories { travelAlerts { %s } } }" % g
res = {}
with ThreadPoolExecutor(8) as ex:
    for (n, q), (s, p) in zip(Q.items(), ex.map(lambda q: post(q), Q.values())):
        errs = [e.get("message", "")[:240] for e in (p.get("errors") or []) if isinstance(e, dict)]
        res[n] = {"status": s, "errors": errs, "data": json.dumps(p.get("data"))[:2500] if p.get("data") is not None else None}
json.dump(res, open(os.path.join(OUT, "results.json"), "w"), indent=1)
lines = ["# Alert groups and lines\n"]
for n, v in res.items():
    hint = [e for e in v["errors"] if "Did you mean" in e or "selection" in e or "argument" in e.lower()]
    if (v["status"] == 200 and v["data"] and v["data"] != "null") or hint:
        lines.append(f"- {n}: {v['status']} | {' / '.join(hint)[:250]} | {(v['data'] or '')[:1200]}")
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))
