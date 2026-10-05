#!/usr/bin/env python3
"""Check the hand-picked trip planner names and Secaucus's board name."""
import json, os, sys, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

URL = "https://www.njtransit.com/api/graphql/graphql"
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)


def post(q, v):
    req = urllib.request.Request(URL, data=json.dumps({"query": q, "variables": v}).encode(), method="POST",
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}


BOARD = "query($s: String!) { getTrainDepartureScreens(station: $s) { items { trainID destination lineAbbreviation } } }"
PLAN = """query($o: String!, $d: String!, $date: String, $time: String) { getTripPlannerSchedule(origin: $o, destination: $d,
  timeOption: "D", date: $date, time: $time, accessible: false, travelMode: "CTR", maxWalkingDistance: "1.00", minimizeTime: "T") {
  duration legs { block onStopDescription offStopDescription routeType } } }"""
day = datetime.now(timezone(timedelta(hours=-4))) + timedelta(days=1)
while day.weekday() >= 5:
    day += timedelta(days=1)
date = day.strftime("%m/%d/%Y")

planner = ["Broadway Station Fair Lawn", "Essex Street Station (PVL)", "Ho-Ho-Kus Station",
           "Jersey Avenue Station (Northeast Corridor)", "Middletown New Jersey Station", "Middletown New York Station",
           "Montclair State University Station", "Pennsauken Transit Center Station", "Philadelphia 30th Street Station",
           "30th Street Station Philadelphia", "Radburn Station", "Secaucus Junction Station", "TRENTON",
           "Trenton Transit Center", "Trenton Station", "Wayne-Route 23 Transit Center Rail Station",
           "Watchung Avenue Station", "Princeton Station", "Princeton Junction Station"]
boards = ["Secaucus Junction", "Secaucus", "Frank R Lautenberg Secaucus", "Frank R. Lautenberg Secaucus Junction",
          "Secaucus Upper Level", "Secaucus Lower Level", "Secaucus Jct", "Secaucus Junction Station",
          "Secaucus Upper Lvl", "Watchung Avenue", "Trenton", "Princeton", "Princeton Junction"]


def plan(name):
    dest = "Hoboken Terminal"
    s, p = post(PLAN, {"o": name, "d": dest, "date": date, "time": "8:00 AM"})
    errs = [e.get("message", "")[:160] for e in (p.get("errors") or [])] if isinstance(p, dict) else []
    sched = ((p.get("data") or {}).get("getTripPlannerSchedule")) if isinstance(p, dict) else None
    first = ""
    if sched:
        legs = [l for l in sched[0].get("legs", []) if l.get("block")]
        first = " | ".join(f"{l['block']} {l['onStopDescription']} > {l['offStopDescription']}" for l in legs)
    return {"name": name, "status": s, "itineraries": len(sched or []), "errors": errs, "first": first}


def board(name):
    s, p = post(BOARD, {"s": name})
    items = (((p.get("data") or {}).get("getTrainDepartureScreens") or {}).get("items")) if isinstance(p, dict) else None
    errs = [e.get("message", "")[:120] for e in (p.get("errors") or [])] if isinstance(p, dict) else []
    return {"name": name, "status": s, "items": len(items) if items is not None else None, "errors": errs,
            "sample": (items or [])[:3]}


with ThreadPoolExecutor(8) as ex:
    plans = list(ex.map(plan, planner))
    bds = list(ex.map(board, boards))
json.dump({"plans": plans, "boards": bds}, open(os.path.join(OUT, "check.json"), "w"), indent=1)
lines = [f"# Hand-picked names (planner date {date})\n", "## Planner"]
lines += [f"- {r['name']}: {r['itineraries']} itineraries {r['errors'][:1]} {r['first'][:160]}" for r in plans]
lines += ["", "## Boards"]
lines += [f"- {r['name']}: items {r['items']} {r['errors'][:1]} {json.dumps(r['sample'])[:200]}" for r in bds]
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))
