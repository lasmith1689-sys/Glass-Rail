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

def planner(o, d, at, minimize="T", tag=""):
    v = {"origin": PLAN_NAME[o], "destination": PLAN_NAME[d], "timeOption": "D", "date": at.strftime("%m/%d/%Y"),
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
        its.append({"train": legs[0]["block"].strip(), "dep": dep, "arr": arr, "xfers": len(legs) - 1,
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
def day_at(days, h, m):
    d = (now + timedelta(days=days)).date()
    return datetime(d.year, d.month, d.day, h, m, tzinfo=ET)
nd = 1
while (now + timedelta(days=nd)).weekday() >= 5:
    nd += 1
AM = ["watchung>hoboken", "watchung>penn"]
PM = ["hoboken>watchung", "penn>watchung"]
scen = [("now", now, AM + PM), ("next-weekday-0650", day_at(nd, 6, 50), AM)]
if now.hour < 16:
    scen += [("today-1645", day_at(0, 16, 45), PM), ("today-1740", day_at(0, 17, 40), PM)]
WINDOW = timedelta(minutes=225)
GRID = 10

class Dir:
    """Every real lookup for one scenario-direction, cached by minute."""
    def __init__(self, o, d, base):
        self.o, self.d, self.base = o, d, base
        self.cache, self.lock = {}, threading.Lock()
    def look(self, t):
        t = t.replace(second=0, microsecond=0)
        with self.lock:
            if t in self.cache:
                return self.cache[t]
        r = planner(self.o, self.d, t)
        r["at"] = t
        with self.lock:
            self.cache[t] = r
        return r
    def many(self, times):
        with ThreadPoolExecutor(6) as ex:
            return list(ex.map(self.look, times))

def deps_of(rs):
    return sorted({i["dep"] for r in rs for i in r["its"] if i["dep"]})

def gap_probe(dr, anchors, G, rounds=5, budget=16):
    """Anchors, then probe every unexplained hole between known departures."""
    looked = {}
    for r in dr.many([dr.base + timedelta(minutes=m) for m in anchors]):
        looked[r["at"]] = r
    extra = 0
    end = dr.base + WINDOW
    for _ in range(rounds):
        known = [x for x in deps_of(looked.values()) if x <= end]
        starts = sorted(looked)
        probes = []
        points = sorted(set([dr.base] + known))
        for a, b in zip(points, points[1:]):
            inside = [s for s in starts if a < s <= b]
            first = min(inside) if inside else b
            if first - a > timedelta(minutes=G):
                t = a + timedelta(minutes=1)
                if t not in looked and t not in probes:
                    probes.append(t)
        # Beyond the last known departure, up to the window end.
        if known and end - known[-1] > timedelta(minutes=G) and not [s for s in starts if s > known[-1]]:
            probes.append(known[-1] + timedelta(minutes=1))
        probes = probes[: max(0, budget - extra)]
        if not probes:
            break
        extra += len(probes)
        for r in dr.many(probes):
            looked[r["at"]] = r
    return looked

results, md = {}, [f"# Planner strategies vs a {GRID}-minute ground truth\n\nRun at {now.strftime('%a %d %b %Y %-I:%M %p')} Eastern. Window: first {int(WINDOW.total_seconds()//60)} minutes.\n"]
def run(label, base, dirn):
    o, d = dirn.split(">")
    dr = Dir(o, d, base)
    dr.many([base + timedelta(minutes=m) for m in range(0, int(WINDOW.total_seconds()//60) + 1, GRID)])
    strategies = {
        "A fixed 0/75/150/225 (app today)": lambda: {r["at"]: r for r in dr.many([base + timedelta(minutes=m) for m in [0, 75, 150, 225]])},
        "E every 20 min": lambda: {r["at"]: r for r in dr.many([base + timedelta(minutes=m) for m in range(0, 221, 20)])},
        "B fixed + gap probe 15": lambda: gap_probe(dr, [0, 75, 150, 225], 15),
        "C fixed + gap probe 10": lambda: gap_probe(dr, [0, 75, 150, 225], 10),
        "D every 30 + gap probe 15": lambda: gap_probe(dr, list(range(0, 211, 30)), 15),
    }
    out = {name: f() for name, f in strategies.items()}
    return label, base, dirn, dr, out

jobs = [(label, base, dirn) for label, base, dirs in scen for dirn in dirs]
with ThreadPoolExecutor(3) as ex:
    outs = list(ex.map(lambda a: run(*a), jobs))

for label, base, dirn, dr, out in outs:
    end = base + WINDOW
    gt = {key(i): i for i in best_per_key([i for r in dr.cache.values() for i in r["its"]]) if i["dep"] <= end}
    md.append(f"## {label} ({base.strftime('%a %-I:%M %p')}) {dirn}: {len(gt)} trips in the ground truth\n")
    res = {"gt": [fmt_trip(i) for i in sorted(gt.values(), key=lambda i: i["dep"])], "strategies": {}}
    for name, looked in out.items():
        found = {key(i) for r in looked.values() for i in r["its"]}
        miss = [gt[k] for k in sorted(gt, key=lambda k: k[1]) if k not in found]
        errs = sum(1 for r in looked.values() if r["error"] and not r["notrips"])
        md.append(f"- {name}: {len(looked)} lookups{f' ({errs} failed)' if errs else ''}, found {len(gt) - len(miss)}/{len(gt)}; missing: " + (", ".join(fmt_trip(i) for i in miss) or "none"))
        res["strategies"][name] = {"lookups": len(looked), "found": len(gt) - len(miss), "missing": [fmt_trip(i) for i in miss]}
    md.append("")
    results[f"{label} {dirn}"] = res

md.append(f"{len(calls)} requests, {sum(1 for c in calls if c['status'] != 200)} non-200.\n")
with open(os.path.join(OUT, "results.json"), "w") as f:
    json.dump({"now": now.isoformat(), "results": results, "calls": calls}, f, indent=1, default=str)
with open(os.path.join(OUT, "summary.md"), "w") as f:
    f.write("\n".join(md))
print("\n".join(md))
