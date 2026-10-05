#!/usr/bin/env python3
"""Find NJ Transit's rail station list: root fields (from "Did you mean" suggestions), then
their subfields, so any station can be a rider's home."""
import json, os, re, sys, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

URL = "https://www.njtransit.com/api/graphql/graphql"
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)


def post(q):
    req = urllib.request.Request(URL, data=json.dumps({"query": q, "variables": {}}).encode(), method="POST",
                                 headers={"content-type": "application/json"})
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


def run(queries):
    out = {}
    with ThreadPoolExecutor(8) as ex:
        for (n, q), (s, p) in zip(queries.items(), ex.map(post, queries.values())):
            errs = [e.get("message", "")[:400] for e in (p.get("errors") or []) if isinstance(e, dict)]
            out[n] = {"status": s, "errors": errs,
                      "data": json.dumps(p.get("data"))[:6000] if p.get("data") is not None else None}
    return out


ROOT = ["getStations", "getStation", "getTrainStations", "getTrainStation", "getRailStations", "getRailStation",
        "getStationList", "getTrainStationList", "getAllStations", "getStops", "getTrainStops", "getRailStops",
        "stations", "trainStations", "getTripPlannerLocations", "getTripPlannerLocation", "getLocations",
        "getLocation", "getDVStations", "getDepartureVisionStations", "getTrainStationsList", "getStationsByLine",
        "getLineStations", "getTrainLineStations", "searchLocations", "getAutocomplete", "getPlaces",
        "getTrainStationsByLine", "getRailStationList", "getStationNames", "getTrainStopList", "getTrainLines",
        "getTrainDepartureScreens", "getTripPlannerSchedule", "getRailAlertsAdvisories", "getBusStops",
        "getLightRailStations", "getTrainStationInfo", "getStationInfo", "getStationDetails", "getTrainSchedule",
        "getStationSchedule", "getTrainStationSchedule", "getTrainSchedules", "getDepartureVision", "getStopsByName"]
SUB = ["zzzz", "name", "stationName", "station", "displayName", "title", "label", "code", "stationCode", "id",
       "stationId", "latLong", "lat", "lng", "latitude", "longitude", "lines", "line", "lineCodes", "routes",
       "abbreviation", "value", "dvName", "plannerName", "address", "description", "stops", "stations",
       "stopName", "stopId", "stop_name", "stop_id", "shortName", "longName", "slug", "nid", "type", "city",
       "railLines", "trainLines", "lineAbbreviation", "lineName", "stationList", "items"]

lines = ["# NJ Transit station discovery\n"]
root = run({f"root.{f}": "{ %s }" % f for f in ROOT})
suggested = set()
for n, v in root.items():
    for e in v["errors"]:
        suggested.update(re.findall(r'"([A-Za-z_]+)"', e.split("Did you mean", 1)[1]) if "Did you mean" in e else [])
lines.append("## Root fields")
for n, v in root.items():
    lines.append(f"- {n}: {v['status']} | {' / '.join(v['errors'])[:400]} | {(v['data'] or '')[:300]}")
known = {"getTrainStopList", "getTrainDepartureScreens", "getTripPlannerSchedule", "getRailAlertsAdvisories",
         "getTrainLines"}
candidates = sorted((suggested | {f for f in ROOT if any("must have a selection" in e or "argument" in e for e in root[f"root.{f}"]["errors"])}) - set())
lines.append(f"\nSuggested or real: {sorted(suggested)}\nCandidates for subfields: {candidates}\n")

sub_queries = {}
for f in candidates + ["getTrainLines"]:
    for s in SUB:
        sub_queries[f"{f}.{s}"] = "{ %s { %s } }" % (f, s)
sub = run(sub_queries)
lines.append("## Subfields")
for n, v in sub.items():
    hint = [e for e in v["errors"] if "Did you mean" in e or "selection" in e or "argument" in e.lower() or "on type" in e]
    good = v["status"] == 200 and v["data"] and v["data"] != "null" and not v["errors"]
    if good or hint:
        lines.append(f"- {n}: {v['status']} | {' / '.join(hint)[:300]} | {(v['data'] or '')[:1500]}")

json.dump({"root": root, "sub": sub}, open(os.path.join(OUT, "results.json"), "w"), indent=1)
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))
