#!/usr/bin/env python3
"""Build a catalog of NJ Transit rail stations a rider can call home: every station's board name
(as stop lists name it), its lines, and its trip planner name, each checked live."""
import json, os, re, sys, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

URL = "https://www.njtransit.com/api/graphql/graphql"
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)


def post(q, v=None):
    req = urllib.request.Request(URL, data=json.dumps({"query": q, "variables": v or {}}).encode(), method="POST",
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


def pmap(fn, items, n=8):
    with ThreadPoolExecutor(n) as ex:
        return list(ex.map(fn, items))


BOARD = "query($s: String!) { getTrainDepartureScreens(station: $s) { items { trainID destination lineAbbreviation departureDate } } }"
STOPS = "query($t: String!) { getTrainStopList(train: $t) { name time } }"
PLAN = """query($o: String!, $d: String!, $date: String, $time: String) { getTripPlannerSchedule(origin: $o, destination: $d,
  timeOption: "D", date: $date, time: $time, accessible: false, travelMode: "CTR", maxWalkingDistance: "1.00", minimizeTime: "T") {
  duration legs { block onStopDescription offStopDescription routeType } } }"""


def board(name):
    s, p = post(BOARD, {"s": name})
    items = (((p.get("data") or {}).get("getTrainDepartureScreens") or {}).get("items")) if isinstance(p, dict) else None
    errs = [e.get("message", "")[:200] for e in (p.get("errors") or [])] if isinstance(p, dict) else []
    return {"status": s, "items": items, "errors": errs}


# 1. Trains on every line, from the terminals' and big stations' boards.
seeds = ["Hoboken Terminal", "New York Penn Station", "Newark Penn Station", "Secaucus Upper Lvl", "Secaucus Lower Lvl",
         "Newark Broad Street", "Summit", "Trenton", "Long Branch", "Dover", "Raritan", "Suffern", "Bay Head",
         "Hackettstown", "Gladstone", "High Bridge", "Spring Valley", "Port Jervis", "Atlantic City", "Princeton",
         "Montclair State U", "Philadelphia", "Lindenwold", "Woodbridge", "Watchung Avenue", "Bay Street"]
seed_boards = dict(zip(seeds, pmap(board, seeds)))
trains = {}
for name, b in seed_boards.items():
    for it in b["items"] or []:
        t = (it.get("trainID") or "").strip()
        if t:
            trains.setdefault(t, it.get("lineAbbreviation") or "")

# 2. Stop lists: every station name, with the lines that serve it.
def stops(t):
    s, p = post(STOPS, {"t": t})
    return t, ((p.get("data") or {}).get("getTrainStopList") or []) if isinstance(p, dict) else []
stations = {}
for t, lst in pmap(stops, sorted(trains)):
    for st in lst:
        nm = (st.get("name") or "").strip()
        if nm:
            stations.setdefault(nm, set()).add(trains[t])

# 3. Each station's own board works under that name?
names = sorted(stations)
checks = dict(zip(names, pmap(board, names)))
bogus = board("Nowhere At All")

# 4. Planner names: candidates from the planner's location list, each tried live.
_, locs = post("{ getTripPlannerLocations { title latitude longitude } }")
loc_list = ((locs.get("data") or {}).get("getTripPlannerLocations") or []) if isinstance(locs, dict) else []
titles = {l["title"]: l for l in loc_list}


def norm(x):
    x = x.lower().replace("&", "and")
    x = re.sub(r"\b(station|terminal|lvl|level|st|street|ave|avenue|jct|junction|rail|train)\b", " ", x)
    return " ".join(re.sub(r"[^a-z0-9 ]", " ", x).split())


def candidates(nm):
    out = [c for c in (nm + " Station", nm, nm.replace(" Lvl", " Level") + " Station") if c in titles]
    key = norm(nm)
    out += [t for t in titles if t not in out and norm(t) == key and (t.endswith("Station") or t.endswith("Terminal"))]
    return out[:4]


tomorrow = datetime.now(timezone(timedelta(hours=-4))) + timedelta(days=1)
while tomorrow.weekday() >= 5:
    tomorrow += timedelta(days=1)
date = tomorrow.strftime("%m/%d/%Y")


def plan_check(nm):
    results = []
    for c in candidates(nm):
        dest = "Hoboken Terminal" if c != "Hoboken Terminal" else "New York Penn Station"
        s, p = post(PLAN, {"o": c, "d": dest, "date": date, "time": "8:00 AM"})
        errs = [e.get("message", "")[:160] for e in (p.get("errors") or [])] if isinstance(p, dict) else []
        n = len(((p.get("data") or {}).get("getTripPlannerSchedule")) or []) if isinstance(p, dict) else 0
        results.append({"name": c, "status": s, "itineraries": n, "errors": errs})
        if n > 0:
            break
    return results


plans = dict(zip(names, pmap(plan_check, names)))

catalog = []
for nm in names:
    b = checks[nm]
    ok_plan = next((r["name"] for r in plans[nm] if r["itineraries"] > 0), None)
    loc = titles.get(ok_plan or "", {})
    catalog.append({"name": nm, "lines": sorted(l for l in stations[nm] if l), "board_ok": b["status"] == 200 and b["items"] is not None and not b["errors"],
                    "board_items": len(b["items"] or []), "board_errors": b["errors"], "planner": ok_plan,
                    "planner_tries": plans[nm], "lat": loc.get("latitude"), "lon": loc.get("longitude")})

json.dump({"seed_boards": {k: {"n": len(v["items"] or []), "errors": v["errors"]} for k, v in seed_boards.items()},
           "trains": trains, "bogus_board": bogus, "catalog": catalog}, open(os.path.join(OUT, "catalog.json"), "w"), indent=1)
lines = [f"# Station catalog ({len(catalog)} stations from {len(trains)} trains; planner date {date})\n",
         f"Seed boards: " + ", ".join(f"{k} {len(v['items'] or [])}{' ERR ' + v['errors'][0][:60] if v['errors'] else ''}" for k, v in seed_boards.items()),
         f"Bogus board: {json.dumps(bogus)[:300]}",
         f"Line codes on boards: {sorted(set(trains.values()))}\n"]
for c in catalog:
    flag = "" if c["board_ok"] and c["planner"] else "  <-- CHECK"
    lines.append(f"- {c['name']} | lines {','.join(c['lines'])} | board {'ok' if c['board_ok'] else 'NO'} ({c['board_items']}) | planner {c['planner']}{flag}")
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))
