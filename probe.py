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

AM = ["watchung>hoboken", "watchung>penn"]
PM = ["hoboken>watchung", "penn>watchung"]
scen = [("now", now, AM + PM)]
nd = 1
while (now + timedelta(days=nd)).weekday() >= 5:
    nd += 1
scen.append(("next-weekday-0650", day_at(nd, 6, 50), AM))
if now.hour < 16:
    scen.append(("today-1645", day_at(0, 16, 45), PM))
    scen.append(("today-1745", day_at(0, 17, 45), PM))
else:
    scen.append(("next-1645", day_at(1, 16, 45), PM))

results, md = {}, []
md.append(f"# NJ Transit planner probe\n\nRun at {now.strftime('%a %d %b %Y %-I:%M %p')} Eastern.\n")

def run_dir(label, base, dirn):
    o, d = dirn.split(">")
    fx = fixed_window(o, d, base)
    ch = chained_window(o, d, base)
    return label, base, dirn, fx, ch

jobs = [(label, base, dirn) for label, base, dirs in scen for dirn in dirs]
with ThreadPoolExecutor(6) as ex:
    outs = list(ex.map(lambda a: run_dir(*a), jobs))

for label, base, dirn, fx, ch in outs:
    fx_its = best_per_key([i for r in fx for i in r["its"]])
    ch_its = best_per_key([i for r in ch for i in r["its"]])
    fx_keys = {key(i) for i in fx_its}
    fx_end = max((i["dep"] for i in fx_its), default=base)
    missing = [i for i in ch_its if key(i) not in fx_keys and i["dep"] <= fx_end]
    missing_trains = sorted({i["train"] for i in missing})
    extra = [i for i in fx_its if key(i) not in {key(j) for j in ch_its}]
    results[f"{label} {dirn}"] = {
        "base": base.isoformat(),
        "fixed": {"lookups": [{"returned": r.get("returned", 0), "rail": len(r["its"]), "error": r["error"], "notrips": r["notrips"]} for r in fx],
                  "trips": [fmt_trip(i) for i in fx_its]},
        "chained": {"lookups": [{"at": r["at"].isoformat(), "returned": r.get("returned", 0), "rail": len(r["its"]), "error": r["error"], "notrips": r["notrips"],
                                 "deps": [fmt_trip(i) for i in r["its"]]} for r in ch],
                    "trips": [fmt_trip(i) for i in ch_its]},
        "missing_from_fixed": [fmt_trip(i) for i in missing],
        "only_in_fixed": [fmt_trip(i) for i in extra],
    }
    md.append(f"## {label} ({base.strftime('%a %-I:%M %p')}) {dirn}\n")
    md.append(f"- Fixed lookups returned {[r.get('returned', 0) for r in fx]} itineraries"
              f"{' errors: ' + '; '.join(str(r['error'])[:80] for r in fx if r['error']) if any(r['error'] for r in fx) else ''}; "
              f"{len(fx_its)} distinct trips up to {hm(fx_end)}.")
    md.append(f"- Chained: {len(ch)} lookups returned {[r.get('returned', 0) for r in ch]}; {len(ch_its)} distinct trips up to {hm(max((i['dep'] for i in ch_its), default=base))}.")
    md.append(f"- **Missing from the app's fixed window (before {hm(fx_end)}): {len(missing)} trips, {len(missing_trains)} first trains**: " + (", ".join(fmt_trip(i) for i in missing) or "none"))
    if extra:
        md.append(f"- Only in fixed: " + ", ".join(fmt_trip(i) for i in extra))
    md.append("- Chained trips: " + ", ".join(fmt_trip(i) for i in ch_its) + "\n")

# Boards now, against the chained 'now' results.
first_trains = {}
for label, base, dirn, fx, ch in outs:
    if label == "now":
        first_trains[dirn] = {i["train"] for r in ch for i in r["its"]}
        first_trains[dirn + " (fixed)"] = {i["train"] for r in fx for i in r["its"]}
boards = {}
for st in ["Watchung Avenue", "Hoboken Terminal", "New York Penn Station", "Bay Street"]:
    status, p = post(BOARD, {"station": st}, f"board-{st}")
    items = (((p.get("data") or {}).get("getTrainDepartureScreens") or {}).get("items") or []) if isinstance(p.get("data"), dict) else []
    boards[st] = items
    md.append(f"## Board {st}: HTTP {status}, {len(items)} trains\n")
    for it in items:
        tid = (it.get("trainID") or "").strip()
        tags = [dirn for dirn, s in first_trains.items() if tid in s]
        if st == "Watchung Avenue" or (it.get("lineAbbreviation") or "") in ("MOBO", "M&E", "ME"):
            md.append(f"- {tid} {it.get('departureDate')} to {it.get('destination')} [{it.get('lineAbbreviation')}] trk {it.get('track')} {it.get('status') or ''}"
                      f" | planner: {', '.join(tags) if tags else 'NOT in any planner result'}")
    md.append("")

# minimizeTime variants now.
md.append("## minimizeTime variants (now)\n")
variants = {}
for dirn in AM + PM:
    o, d = dirn.split(">")
    for mval in ["T", "F", None]:
        r = planner(o, d, now, minimize=mval, tag=f"variant-{o}-{d}-{mval}")
        variants[f"{dirn} {mval}"] = [fmt_trip(i) for i in r["its"]] if not r["error"] else r["error"]
        md.append(f"- {dirn} minimizeTime={mval}: " + (", ".join(fmt_trip(i) for i in r["its"]) if not r["error"] else f"error: {r['error'][:120]}"))
md.append("")

status, p = post(INTROSPECT, {}, "introspection")
fields = []
try:
    for f in p["data"]["__schema"]["queryType"]["fields"]:
        fields.append(f["name"] + "(" + ", ".join(a["name"] for a in f.get("args") or []) + ")")
except Exception:
    fields = [f"introspection unavailable: HTTP {status} {str(p)[:300]}"]
md.append("## Query fields (introspection)\n\n" + "\n".join(f"- {x}" for x in fields) + "\n")
md.append(f"{len(calls)} requests, {sum(1 for c in calls if c['status'] != 200)} non-200.\n")

with open(os.path.join(OUT, "results.json"), "w") as f:
    json.dump({"now": now.isoformat(), "results": results, "variants": variants, "fields": fields, "calls": calls,
               "boards": boards}, f, indent=1, default=str)
with open(os.path.join(OUT, "summary.md"), "w") as f:
    f.write("\n".join(md))
print("\n".join(md))
