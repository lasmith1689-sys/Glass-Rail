#!/usr/bin/env python3
"""One-off NJ Transit probe (Glass Rail): which trains does the app's planner window miss?

Compares, per direction, the app's four fixed planner lookups (now, +75, +150, +225 min)
with a chained window (each lookup starts just after the last departure the previous one
returned), and checks both against the live departure boards."""
import json, os, re, sys, time, threading, urllib.request, urllib.error
from datetime import datetime, timedelta
from concurrent.futures import ThreadPoolExecutor
from zoneinfo import ZoneInfo

ET = ZoneInfo("America/New_York")
URL = "https://www.njtransit.com/api/graphql/graphql"
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(os.path.join(OUT, "raw"), exist_ok=True)

PLANNER = """query TripPlannerSchedule($origin: String!, $destination: String!, $timeOption: String, $date: String, $time: String, $accessible: Boolean, $travelMode: String, $maxWalkingDistance: String, $minimizeTime: String) {
  getTripPlannerSchedule(origin: $origin, destination: $destination, timeOption: $timeOption, date: $date, time: $time, accessible: $accessible, travelMode: $travelMode, maxWalkingDistance: $maxWalkingDistance, minimizeTime: $minimizeTime) {
    duration
    legs { route routeType sign onStopDescription onStopTime offStopDescription offStopTime block }
  }
}"""
BOARD = """query DepartureScreen($station: String!) { getTrainDepartureScreens(station: $station) { items { departureDate destination inlineMessage lineAbbreviation status track trainID } } }"""
INTROSPECT = """{ __schema { queryType { fields { name args { name type { kind name ofType { kind name ofType { kind name } } } } } } } }"""

PLAN_NAME = {"watchung": "Watchung Avenue Station", "hoboken": "Hoboken Terminal", "penn": "New York Penn Station", "baystreet": "Bay Street Station"}
FIXED = [0, 75, 150, 225]
CHAIN_MAX = 16
HORIZON = timedelta(hours=5)

lock = threading.Lock()
calls = []
raw_n = [0]

def post(query, variables, tag):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(URL, data=body, method="POST", headers={"content-type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except Exception as e:  # network
        status, raw = 0, str(e).encode()
    secs = round(time.time() - t0, 2)
    try:
        payload = json.loads(raw)
    except Exception:
        payload = {"_raw": raw[:400].decode("utf-8", "replace")}
    with lock:
        raw_n[0] += 1
        n = raw_n[0]
        calls.append({"n": n, "tag": tag, "status": status, "seconds": secs})
    with open(os.path.join(OUT, "raw", f"{n:03d}-{re.sub(r'[^A-Za-z0-9_.-]+', '_', tag)}.json"), "w") as f:
        json.dump({"variables": variables, "status": status, "reply": payload}, f)
    return status, payload

def parse_time(raw, base):
    s = " ".join((raw or "").split())
    m = re.match(r"^(\d{1,2})-([A-Za-z]{3})-(\d{4}) (\d{1,2}):(\d{2}):(\d{2}) ([AP]M)$", s)
    months = {k: i for i, k in enumerate("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(), 1)}
    if m:
        h = int(m[4]) % 12 + (12 if m[7] == "PM" else 0)
        return datetime(int(m[3]), months[m[2]], int(m[1]), h, int(m[5]), int(m[6]), tzinfo=ET)
    m = re.match(r"^(\d{1,2}):(\d{2}) ?([AP]M)$", s, re.I)
    if not m:
        return None
    h = int(m[1]) % 12 + (12 if m[3].upper() == "PM" else 0)
    cand = base.replace(hour=h, minute=int(m[2]), second=0, microsecond=0)
    if cand < base - timedelta(hours=8):
        cand += timedelta(days=1)
    return cand

def hm(d):
    return d.strftime("%-I:%M %p") if d else "?"

def rail_legs(it):
    return [l for l in (it.get("legs") or []) if (l.get("routeType") or "").strip() == "C" and (l.get("block") or "").strip()
            and (l.get("onStopTime") or "").strip() and (l.get("offStopTime") or "").strip()]

def planner(o, d, at, minimize="T", tag="", option="D"):
    v = {"origin": PLAN_NAME[o], "destination": PLAN_NAME[d], "timeOption": option, "date": at.strftime("%m/%d/%Y"),
         "time": at.strftime("%-I:%M %p"), "accessible": False, "travelMode": "CTR", "maxWalkingDistance": "1.00"}
    if minimize is not None:
        v["minimizeTime"] = minimize
    status, p = post(PLANNER, v, tag or f"plan-{o}-{d}-{at.strftime('%m%d-%H%M')}")
    errs = p.get("errors") or []
    sched = (p.get("data") or {}).get("getTripPlannerSchedule") if isinstance(p.get("data"), dict) else None
    if errs and not sched:
        msg = " | ".join(e.get("message", "") for e in errs)
        return {"status": status, "error": msg, "notrips": "unable to find trips" in msg.lower(), "its": []}
    if status != 200 or sched is None:
        return {"status": status, "error": f"HTTP {status} {str(p)[:200]}", "notrips": False, "its": []}
    its = []
    for it in sched:
        legs = rail_legs(it)
        if not legs:
            continue
        dep = parse_time(legs[0]["onStopTime"], at)
        arr = parse_time(legs[-1]["offStopTime"], at)
        its.append({"routes": [(l.get("routeType"), l.get("route"), l.get("onStopDescription"), l.get("offStopDescription"), l.get("onStopTime"), l.get("offStopTime")) for l in it.get("legs") or []], "last": (legs[-1].get("offStopDescription") or "").strip(), "train": legs[0]["block"].strip(), "dep": dep, "arr": arr, "xfers": len(legs) - 1,
                    "via": [ (l.get("onStopDescription") or "").strip() for l in legs[1:] ],
                    "legs": [l["block"].strip() for l in legs]})
    return {"status": status, "error": None, "notrips": False, "its": its, "returned": len(sched)}

def key(i):
    return (i["train"], i["dep"])

def best_per_key(its):
    best = {}
    for i in its:
        k = key(i)
        b = best.get(k)
        if b is None or (i["xfers"], i["arr"] or datetime.max.replace(tzinfo=ET)) < (b["xfers"], b["arr"] or datetime.max.replace(tzinfo=ET)):
            best[k] = i
    return sorted(best.values(), key=lambda i: i["dep"])

def fixed_window(o, d, base):
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda m: planner(o, d, base + timedelta(minutes=m)), FIXED))
    return res

def chained_window(o, d, base):
    res, t = [], base
    for _ in range(CHAIN_MAX):
        r = planner(o, d, t)
        r["at"] = t
        res.append(r)
        deps = [i["dep"] for i in r["its"] if i["dep"]]
        if not deps:
            break
        nxt = max(deps) + timedelta(minutes=1)
        if nxt <= t:
            nxt = t + timedelta(minutes=1)
        if nxt > base + HORIZON:
            break
        t = nxt
    return res

def fmt_trip(i):
    s = f"{i['train']} {hm(i['dep'])}->{hm(i['arr'])}"
    if i["xfers"]:
        s += " via " + "/".join(v.title() for v in i["via"])
    return s


now = datetime.now(ET).replace(second=0, microsecond=0)
def at_today(hhmm):
    h, m = map(int, hhmm.split(":"))
    return now.replace(hour=h, minute=m)
nd = 1
while (now + timedelta(days=nd)).weekday() >= 5:
    nd += 1
def at_next(hhmm):
    h, m = map(int, hhmm.split(":"))
    d = (now + timedelta(days=nd))
    return d.replace(hour=h, minute=m)

# Ground truth from probe 2 (4:45 PM today and 6:50 AM next weekday), as (train, dep, arr, via).
PM_GT = {
 "hoboken": [("1055","17:12","17:42"),("267","17:23","18:00"),("1009","17:50","18:22"),("275","17:56","18:33"),("339","18:07","18:54"),("1011","18:33","19:09"),("657","18:38","19:23"),("1085","19:22","19:59"),("665","19:34","20:17"),("1643","20:22","21:15"),("1087","20:58","21:34")],
 "penn": [("6263","16:52","17:30"),("6647","17:13","18:00"),("6273","17:31","18:10"),("6651","17:43","18:22"),("6279","18:14","18:54"),("6655","18:21","19:09"),("6283","18:41","19:23"),("6363","19:13","19:59"),("6291","19:37","20:17"),("6667","20:05","21:34")],
}
AM_GT = {
 "hoboken": [("6206","06:50"),("1000","07:08"),("208","07:21"),("6210","07:28"),("1002","07:44"),("212","08:00"),("6214","08:14"),("1006","08:23"),("6216","09:05"),("1074","09:51"),("6222","10:13")],
 "penn": [("6206","06:50"),("1000","07:08"),("208","07:21"),("6210","07:28"),("1002","07:44"),("212","08:00"),("6214","08:14"),("1006","08:23"),("6216","09:05"),("1074","09:51"),("6222","10:13")],
}
md = [f"# Arrive-by and per-train lookups\n\nRun at {now.strftime('%a %d %b %Y %-I:%M %p')} Eastern.\n"]
out = {"pm": {}, "am": {}, "legs": []}

def pm_case(o, train, dep, arr):
    A = at_today(arr)
    r = planner(o, "watchung", A, option="A", tag=f"A-{o}-{arr}")
    got = [fmt_trip(i) for i in r["its"]]
    best = [i for i in r["its"] if i["arr"] and i["arr"].strftime("%H:%M") == arr]
    latest = max(best, key=lambda i: i["dep"]) if best else None
    ok = latest is not None and latest["dep"].strftime("%H:%M") >= dep
    return o, arr, train, dep, r["error"], got, ok, latest, r

def am_case(d, train, dep):
    T = at_next(dep)
    r = planner("watchung", d, T, tag=f"D-{d}-{dep}")
    trains = [i["train"] for i in r["its"]]
    return d, train, dep, r["error"], [fmt_trip(i) for i in r["its"]], train in trains, (trains[:1] == [train]), r

with ThreadPoolExecutor(6) as ex:
    pm = list(ex.map(lambda a: pm_case(*a), [(o, *t) for o, ts in PM_GT.items() for t in ts]))
    am = list(ex.map(lambda a: am_case(*a), [(d, *t) for d, ts in AM_GT.items() for t in ts]))

md.append("## Evening: arrive-by Watchung at each train's arrival (today)\n")
for o, arr, train, dep, err, got, ok, latest, r in pm:
    md.append(f"- {o} arrive by {arr} (GT best: {train} dep {dep}): {'OK' if ok else 'MISS'}"
              f"{' latest found dep ' + latest['dep'].strftime('%H:%M') if latest else ''}; returned: {err or ' | '.join(got)}")
md.append("\n## Morning: depart-at each Watchung train's time (next weekday)\n")
for d, train, dep, err, got, present, first, r in am:
    md.append(f"- {d} depart {dep} train {train}: {'first' if first else ('present' if present else 'MISSING')}; returned: {err or ' | '.join(got)}")

# Itineraries whose rail legs stop short of the destination (non-rail last legs).
md.append("\n## Itineraries with non-rail legs\n")
seen = 0
for res in [x[-1] for x in pm] + [x[-1] for x in am]:
    for i in res["its"]:
        types = [t[0] for t in i["routes"]]
        if any(t != "C" for t in types) and seen < 12:
            seen += 1
            md.append(f"- {fmt_trip(i)} legs: " + " ; ".join(f"{t[0]}:{t[1]} {t[2]}@{t[4]} -> {t[3]}@{t[5]}" for t in i["routes"]))

ok_pm = sum(1 for x in pm if x[6]); ok_am = sum(1 for x in am if x[5])
md.append(f"\nEvening arrive-by found the best way to catch {ok_pm}/{len(pm)} trains; morning depart-at returned the train for {ok_am}/{len(am)}.")
md.append(f"{len(calls)} requests, {sum(1 for c in calls if c['status'] != 200)} non-200.\n")
with open(os.path.join(OUT, "summary.md"), "w") as f:
    f.write("\n".join(md))
with open(os.path.join(OUT, "results.json"), "w") as f:
    json.dump({"now": now.isoformat(), "calls": calls}, f, indent=1, default=str)
print("\n".join(md))
