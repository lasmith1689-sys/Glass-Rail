#!/usr/bin/env python3
"""Disruption snapshot: raw boards, planner answers and stop lists, plus GraphQL field discovery."""
import json, os, re, sys, time, urllib.request, urllib.error
from datetime import datetime
from zoneinfo import ZoneInfo
from concurrent.futures import ThreadPoolExecutor

ET = ZoneInfo("America/New_York")
URL = "https://www.njtransit.com/api/graphql/graphql"
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(os.path.join(OUT, "raw"), exist_ok=True)
log = []

def post(query, variables=None, name="x"):
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(URL, data=body, method="POST", headers={"content-type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except Exception as e:
        status, raw = 0, str(e).encode()
    try:
        payload = json.loads(raw)
    except Exception:
        payload = {"_raw": raw[:600].decode("utf-8", "replace")}
    with open(os.path.join(OUT, "raw", re.sub(r"[^A-Za-z0-9_.-]+", "_", name) + ".json"), "w") as f:
        json.dump({"variables": variables, "status": status, "seconds": round(time.time() - t0, 2), "reply": payload}, f, indent=1)
    log.append((name, status))
    return status, payload

BOARD = "query DepartureScreen($station: String!) { getTrainDepartureScreens(station: $station) { items { departureDate destination inlineMessage lineAbbreviation status track trainID } } }"
PLANNER = """query TripPlannerSchedule($origin: String!, $destination: String!, $timeOption: String, $date: String, $time: String, $accessible: Boolean, $travelMode: String, $maxWalkingDistance: String, $minimizeTime: String) {
  getTripPlannerSchedule(origin: $origin, destination: $destination, timeOption: $timeOption, date: $date, time: $time, accessible: $accessible, travelMode: $travelMode, maxWalkingDistance: $maxWalkingDistance, minimizeTime: $minimizeTime) {
    duration legs { route routeType sign onStopDescription onStopTime offStopDescription offStopTime block } } }"""
STOPS = "query TrainStopList($train: String!) { getTrainStopList(train: $train) { name time status departed dropOff } }"
NAMES = {"watchung": "Watchung Avenue Station", "hoboken": "Hoboken Terminal", "penn": "New York Penn Station"}
now = datetime.now(ET)
md = [f"# Disruption snapshot {now.strftime('%a %d %b %Y %-I:%M %p')} ET\n"]

boards = {}
for st in ["Watchung Avenue", "Hoboken Terminal", "New York Penn Station"]:
    s, p = post(BOARD, {"station": st}, f"board-{st}")
    items = (((p.get("data") or {}).get("getTrainDepartureScreens") or {}).get("items") or []) if isinstance(p.get("data"), dict) else []
    boards[st] = items
    md.append(f"## Board {st}: HTTP {s}, {len(items)} trains")
    for it in items if st == "Watchung Avenue" else [i for i in items if (i.get("lineAbbreviation") or "") in ("MOBO", "M&E", "ME")]:
        md.append(f"- {it.get('trainID')} {it.get('departureDate')} to {it.get('destination')} trk {it.get('track')} status [{it.get('status')}] msg [{it.get('inlineMessage')}]")
    md.append("")

def plan(o, d):
    v = {"origin": NAMES[o], "destination": NAMES[d], "timeOption": "D", "date": now.strftime("%m/%d/%Y"), "time": now.strftime("%-I:%M %p"),
         "accessible": False, "travelMode": "CTR", "maxWalkingDistance": "1.00", "minimizeTime": "T"}
    s, p = post(PLANNER, v, f"planner-{o}-{d}")
    sched = (p.get("data") or {}).get("getTripPlannerSchedule") if isinstance(p.get("data"), dict) else None
    lines = []
    for it in sched or []:
        lines.append(" | ".join(f"{l.get('routeType')}:{l.get('block')} {l.get('onStopDescription')}@{l.get('onStopTime')} -> {l.get('offStopDescription')}@{l.get('offStopTime')}" for l in it.get("legs") or []))
    return f"## Planner {o} > {d}: HTTP {s}, {len(sched or [])} itineraries " + (json.dumps(p.get("errors"))[:300] if p.get("errors") else "") + "\n" + "\n".join("- " + l for l in lines) + "\n"
for o, d in [("watchung", "penn"), ("watchung", "hoboken"), ("penn", "watchung"), ("hoboken", "watchung")]:
    md.append(plan(o, d))

trains = [i.get("trainID") for i in boards["Watchung Avenue"] if i.get("trainID")][:8]
for t in trains:
    s, p = post(STOPS, {"train": t}, f"stops-{t}")
    stops = ((p.get("data") or {}).get("getTrainStopList") or []) if isinstance(p.get("data"), dict) else []
    md.append(f"## Stops {t}: HTTP {s}, {len(stops)} stops: " + ", ".join(f"{x.get('name')} {x.get('time')}{' departed' if x.get('departed') else ''}{' [' + x['status'] + ']' if x.get('status') else ''}" for x in stops))
md.append("")

# GraphQL field discovery through "Did you mean" suggestions.
probes = {
    "screen-fields": '{ getTrainDepartureScreens(station: "Watchung Avenue") { zzzz } }',
    "item-fields": '{ getTrainDepartureScreens(station: "Watchung Avenue") { items { zzzz } } }',
    "stop-fields": '{ getTrainStopList(train: "6216") { zzzz } }',
    "leg-fields": '{ getTripPlannerSchedule(origin: "Watchung Avenue Station", destination: "Hoboken Terminal") { legs { zzzz } } }',
}
for q in ["getAlerts", "alerts", "getServiceAlerts", "getRailAlerts", "getTravelAlerts", "getAdvisories", "getTrainAlerts",
          "getRailServiceAlerts", "getAlertsByStation", "getStationAlerts", "getBanners", "getBannerMessages", "getMessages",
          "getTravelAdvisories", "getRailAdvisories", "getDepartureVisionAlerts", "getLineAlerts", "getAlert", "getNotifications"]:
    probes["q-" + q] = "{ %s { zzzz } }" % q
md.append("## Field discovery\n")
def run_probe(item):
    name, q = item
    s, p = post(q, {}, "discover-" + name)
    errs = p.get("errors") or (p.get("data") or {}).get("errors") if isinstance(p, dict) else None
    msgs = [e.get("message", "") for e in (errs or []) if isinstance(e, dict)]
    if not msgs and isinstance(p, dict) and "_raw" in p:
        msgs = [p["_raw"][:300]]
    if not msgs and isinstance(p, dict) and p.get("message"):
        msgs = [str(p.get("message"))[:300]]
    return name, s, msgs
with ThreadPoolExecutor(6) as ex:
    for name, s, msgs in ex.map(run_probe, probes.items()):
        md.append(f"- {name}: HTTP {s}: " + " / ".join(m[:300] for m in msgs[:2]))
md.append(f"\n{len(log)} requests, {sum(1 for _, s in log if s != 200)} non-200.")
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(md))
print("\n".join(md))
