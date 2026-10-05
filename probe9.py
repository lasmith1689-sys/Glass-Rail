#!/usr/bin/env python3
"""Fields of NJ Transit's Station and TripPlannerLocation types (from "Did you mean"
suggestions), then the full rail station and planner location lists."""
import json, os, re, sys, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

URL = "https://www.njtransit.com/api/graphql/graphql"
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)


def post(q):
    req = urllib.request.Request(URL, data=json.dumps({"query": q, "variables": {}}).encode(), method="POST",
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, json.dumps({"error": str(e)})


def messages(text):
    return [m.encode().decode("unicode_escape") for m in re.findall(r'"message":\s*"((?:[^"\\]|\\.)*)"', text)]


def run(queries):
    out = {}
    with ThreadPoolExecutor(8) as ex:
        for (n, q), (s, t) in zip(queries.items(), ex.map(post, queries.values())):
            out[n] = {"status": s, "messages": messages(t)[:3], "text": t}
    return out


FIELDS = ["getTrainStations", "getStations", "getTripPlannerLocations", "getTripPlannerLocationsHome",
          "getLightRailStations", "getTrainsNearBy", "getStation", "getLines", "getTripStops"]
SUB = ["zzzz", "name", "names", "title", "label", "stationName", "station", "displayName", "code", "stationCode",
       "id", "stationId", "stopId", "stopName", "stop_id", "stop_name", "latLong", "latlong", "lat", "lng", "lon",
       "latitude", "longitude", "location", "lines", "line", "lineCodes", "routes", "abbreviation", "value",
       "type", "address", "city", "county", "zip", "slug", "nid", "url", "path", "dvName", "dvCode", "fullName",
       "shortName", "longName", "description", "railLines", "trainLines", "parkingInfo", "accessible",
       "isAccessible", "stationType", "mode", "modes", "transitMode", "agency", "category", "tid", "uuid"]

queries = {f"{f}.{s}": "{ %s { %s } }" % (f, s) for f in FIELDS for s in SUB}
queries.update({f"{f}.bare": "{ %s }" % f for f in FIELDS})
res = run(queries)

# Which subfields exist (200 with data, or an error naming a type/argument rather than the field).
found, objects = {}, {}
for n, v in res.items():
    f, s = n.split(".", 1)
    if s == "bare":
        continue
    msg = " / ".join(v["messages"])
    if v["status"] == 200 and '"data"' in v["text"] and not v["messages"]:
        found.setdefault(f, []).append(s)
    elif "must have a selection" in msg:
        objects.setdefault(f, []).append(s)
lines = ["# Station types\n", f"Scalar fields: {json.dumps(found)}\n", f"Object fields: {json.dumps(objects)}\n"]
for n, v in res.items():
    msg = " / ".join(v["messages"])
    if "Did you mean" in msg or "argument" in msg.lower() or "on type" in msg and n.endswith(".zzzz"):
        lines.append(f"- {n}: {v['status']} | {msg[:400]}")

# Full lists with every field that answered (scalars only: one query per field set).
full = {}
for f in ["getTrainStations", "getStations", "getTripPlannerLocations", "getTripPlannerLocationsHome"]:
    scal = found.get(f, [])
    if not scal:
        continue
    status, text = post("{ %s { %s } }" % (f, " ".join(scal)))
    full[f] = {"status": status, "messages": messages(text)[:3], "text": text}
    with open(os.path.join(OUT, f"{f}.json"), "w") as fh:
        fh.write(text)
    lines.append(f"\n## {f} ({status}) fields {scal}: {' / '.join(messages(text))[:300]}\n{text[:3000]}")

json.dump({"probe": {k: {"status": v["status"], "messages": v["messages"]} for k, v in res.items()},
           "found": found, "objects": objects}, open(os.path.join(OUT, "results.json"), "w"), indent=1)
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines)[:20000])
