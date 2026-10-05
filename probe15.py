#!/usr/bin/env python3
"""Train 6263 from Penn Station: what NJ Transit's board, stop list and planner say right now."""
import json, os, sys, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

URL = "https://www.njtransit.com/api/graphql/graphql"
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)
ET = timezone(timedelta(hours=-4))
NOW = datetime.now(ET)


def post(q, v):
    req = urllib.request.Request(URL, data=json.dumps({"query": q, "variables": v}).encode(), method="POST",
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read())
        except Exception:
            return {"error": e.code}
    except Exception as e:
        return {"error": str(e)}


BOARD = "query($s: String!) { getTrainDepartureScreens(station: $s) { items { departureDate destination inlineMessage lineAbbreviation status track trainID } } }"
STOPS = "query($t: String!) { getTrainStopList(train: $t) { name time status departed dropOff } }"
PLAN = """query($o: String!, $d: String!, $opt: String, $date: String, $time: String) { getTripPlannerSchedule(origin: $o,
  destination: $d, timeOption: $opt, date: $date, time: $time, accessible: false, travelMode: "CTR",
  maxWalkingDistance: "1.00", minimizeTime: "T") { duration legs { route routeType sign onStopDescription onStopTime
  offStopDescription offStopTime block } } }"""

out = {"now": NOW.isoformat()}
jobs = {
    "board_penn": (BOARD, {"s": "New York Penn Station"}),
    "board_hoboken": (BOARD, {"s": "Hoboken Terminal"}),
    "board_watchung": (BOARD, {"s": "Watchung Avenue"}),
    "stops_6263": (STOPS, {"t": "6263"}),
    "stops_6273": (STOPS, {"t": "6273"}),
    "stops_6643": (STOPS, {"t": "6643"}),
    "plan_arriveby_530": (PLAN, {"o": "New York Penn Station", "d": "Watchung Avenue Station", "opt": "A", "date": NOW.strftime("%m/%d/%Y"), "time": "5:30 PM"}),
    "plan_now": (PLAN, {"o": "New York Penn Station", "d": "Watchung Avenue Station", "opt": "D", "date": NOW.strftime("%m/%d/%Y"), "time": NOW.strftime("%-I:%M %p")}),
}
with ThreadPoolExecutor(8) as ex:
    results = dict(zip(jobs, ex.map(lambda j: post(*jobs[j]), jobs)))
out.update(results)
json.dump(out, open(os.path.join(OUT, "6263.json"), "w"), indent=1)

lines = [f"# 6263 at {NOW.strftime('%-I:%M:%S %p')} ET\n"]
for name in ["board_penn", "board_hoboken", "board_watchung"]:
    items = (((results[name].get("data") or {}).get("getTrainDepartureScreens") or {}).get("items")) or []
    lines.append(f"## {name}: {len(items)} items")
    for it in items:
        if it.get("trainID") in ("6263", "6273", "6643", "6343", "275", "1055") or name == "board_penn":
            lines.append(f"- {it.get('trainID')} {it.get('departureDate')} to {it.get('destination')} status={it.get('status')!r} track={it.get('track')} msg={it.get('inlineMessage')!r}")
for name in ["stops_6263", "stops_6273", "stops_6643"]:
    stops = ((results[name].get("data") or {}).get("getTrainStopList")) or []
    lines.append(f"\n## {name}: {len(stops)} stops")
    lines += [f"- {s.get('name')} {s.get('time')} status={s.get('status')} departed={s.get('departed')} {s.get('dropOff') or ''}" for s in stops]
for name in ["plan_arriveby_530", "plan_now"]:
    sched = ((results[name].get("data") or {}).get("getTripPlannerSchedule")) or []
    lines.append(f"\n## {name}: {len(sched)} itineraries {json.dumps(results[name].get('errors'))[:200] if results[name].get('errors') else ''}")
    for it in sched:
        lines.append("- " + " | ".join(f"{l.get('block')} {l.get('onStopDescription')} {l.get('onStopTime')} > {l.get('offStopDescription')} {l.get('offStopTime')}" for l in it.get("legs") or []))
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))
