#!/usr/bin/env python3
"""Which upcoming trains the app's planner lookups miss. Ground truth: NJ Transit's trip planner
swept every 10 minutes (leave at, and arrive by) for the next 6 hours, both ways between Watchung
Avenue and Hoboken / Penn Station NY. The app's way: lookups now, +75, +150 and +225 minutes (three
itineraries each) plus one per train on Watchung Avenue's board (up to 8)."""
import json, os, re, sys, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

URL = "https://www.njtransit.com/api/graphql/graphql"
OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)
ET = timezone(timedelta(hours=-4))
NOW = datetime.now(ET).replace(second=0, microsecond=0)

PLAN = """query($o: String!, $d: String!, $opt: String, $date: String, $time: String) { getTripPlannerSchedule(origin: $o,
  destination: $d, timeOption: $opt, date: $date, time: $time, accessible: false, travelMode: "CTR",
  maxWalkingDistance: "1.00", minimizeTime: "T") { duration legs { route routeType sign onStopDescription onStopTime
  offStopDescription offStopTime block } } }"""
BOARD = """query($s: String!) { getTrainDepartureScreens(station: $s) { items { departureDate destination
  lineAbbreviation status track trainID } } }"""


def post(q, v):
    req = urllib.request.Request(URL, data=json.dumps({"query": q, "variables": v}).encode(), method="POST",
                                 headers={"content-type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            try:
                body = json.loads(e.read())
            except Exception:
                body = {}
            if e.code < 500:
                return e.code, body
        except Exception as e:
            body = {"error": str(e)}
    return 0, body


def plan(origin, dest, at, arrive=False):
    s, p = post(PLAN, {"o": origin, "d": dest, "opt": "A" if arrive else "D", "date": at.strftime("%m/%d/%Y"),
                       "time": at.strftime("%-I:%M %p")})
    if not isinstance(p, dict):
        return None
    sched = (p.get("data") or {}).get("getTripPlannerSchedule")
    if sched is None:
        msgs = " ".join(e.get("message", "") for e in (p.get("errors") or []))
        return [] if "unable to find trips" in msgs.lower() else None
    return sched


def rail_legs(it):
    return [l for l in it.get("legs") or [] if (l.get("block") or "").strip()]


def other_transit(it):
    return any((l.get("routeType") or "") not in ("C", "", None) and (l.get("block") or "").strip() == "" and
               (l.get("route") or "").strip() not in ("", "-") for l in it.get("legs") or [])


def to_dt(raw, base):
    # "4:45 PM" or "10/05/2026 4:45 PM"
    raw = (raw or "").strip()
    m = re.search(r"(\d{1,2}):(\d{2})\s*([AP]M)", raw, re.I)
    if not m:
        return None
    h, mi, ap = int(m.group(1)), int(m.group(2)), m.group(3).upper()
    h = h % 12 + (12 if ap == "PM" else 0)
    d = re.search(r"(\d{2})/(\d{2})/(\d{4})", raw)
    day = datetime(int(d.group(3)), int(d.group(1)), int(d.group(2)), tzinfo=ET) if d else base.replace(hour=0, minute=0)
    t = day.replace(hour=h, minute=mi)
    if not d and t < base - timedelta(hours=6):
        t += timedelta(days=1)
    return t


def key_of(it):
    legs = rail_legs(it)
    if not legs:
        return None
    dep = to_dt(legs[0].get("onStopTime"), NOW)
    if dep is None:
        return None
    return (legs[0]["block"].strip(), dep)


def describe(it):
    legs = rail_legs(it)
    arr = to_dt(legs[-1].get("offStopTime"), NOW)
    via = [l.get("offStopDescription", "").title() for l in legs[:-1]]
    return {"train": legs[0]["block"].strip(), "dep": key_of(it)[1].strftime("%-I:%M %p"),
            "arr": arr.strftime("%-I:%M %p") if arr else "?", "legs": [l["block"].strip() for l in legs],
            "via": via}


DIRS = [("watchung", "hoboken", "Watchung Avenue Station", "Hoboken Terminal"),
        ("watchung", "penn", "Watchung Avenue Station", "New York Penn Station"),
        ("hoboken", "watchung", "Hoboken Terminal", "Watchung Avenue Station"),
        ("penn", "watchung", "New York Penn Station", "Watchung Avenue Station")]

boards = {}
for name in ["Watchung Avenue", "Hoboken Terminal", "New York Penn Station"]:
    s, p = post(BOARD, {"s": name})
    boards[name] = (((p.get("data") or {}).get("getTrainDepartureScreens") or {}).get("items")) or []

wa = boards["Watchung Avenue"]
def toward_city(dest):
    return bool(re.search(r"hoboken|new york|penn|newark|secaucus", dest or "", re.I))
wa_times = []
for it in wa:
    t = to_dt(it.get("departureDate"), NOW)
    wa_times.append((t, toward_city(it.get("destination")), it.get("trainID"), it.get("destination")))

jobs = []
for fid, tid, o, d in DIRS:
    for step in range(0, 361, 10):
        jobs.append(("truth", fid, tid, o, d, NOW + timedelta(minutes=step), False))
        jobs.append(("truth", fid, tid, o, d, NOW + timedelta(minutes=step + 20), True))
    for off in (0, 75, 150, 225):
        jobs.append(("clock", fid, tid, o, d, NOW + timedelta(minutes=off), False))
    leaving = fid == "watchung"
    seeds = sorted({t for t, city, _, _ in wa_times if t and city == leaving and NOW - timedelta(minutes=1) <= t <= NOW + timedelta(minutes=225)})[:8]
    for t in seeds:
        jobs.append(("seed", fid, tid, o, d, t, not leaving))


def run(job):
    kind, fid, tid, o, d, at, arrive = job
    return job, plan(o, d, at, arrive)


with ThreadPoolExecutor(6) as ex:
    results = list(ex.map(run, jobs))

sizes = {}
lines = [f"# Upcoming trains: the app's lookups vs a 10-minute sweep ({NOW.strftime('%a %-m/%-d %-I:%M %p')} ET)\n"]
for name, items in boards.items():
    ts = [to_dt(i.get("departureDate"), NOW) for i in items]
    ts = [t for t in ts if t]
    span = f"{min(ts).strftime('%-I:%M %p')} to {max(ts).strftime('%-I:%M %p')}" if ts else "-"
    lines.append(f"- Board {name}: {len(items)} trains, {span}")
lines.append("- Watchung Avenue board: " + "; ".join(f"{t.strftime('%-I:%M') if t else '?'} {tr} to {de}" for t, _, tr, de in sorted(wa_times, key=lambda x: x[0] or NOW)))
failed = sum(1 for _, r in results if r is None)
lines.append(f"- Lookups: {len(results)}, failed {failed}")

summary = {}
for fid, tid, o, d in DIRS:
    truth, app = {}, set()
    for (kind, f, t, _, _, at, arrive), r in results:
        if (f, t) != (fid, tid) or r is None:
            continue
        sizes.setdefault(len(r), 0)
        sizes[len(r)] += 1
        for it in r:
            if other_transit(it):
                continue
            k = key_of(it)
            if not k or k[1] < NOW - timedelta(minutes=1) or k[1] > NOW + timedelta(hours=6):
                continue
            if kind == "truth":
                truth.setdefault(k, describe(it))
            else:
                app.add(k)
                truth.setdefault(k, describe(it))
    rows = sorted(truth.items(), key=lambda kv: kv[0][1])
    missing = [(k, v) for k, v in rows if k not in app]
    def band(k):
        mins = (k[1] - NOW).total_seconds() / 60
        return "0-1h" if mins < 60 else "1-2h" if mins < 120 else "2-4h" if mins < 240 else "4-6h"
    counts = {}
    for k, v in rows:
        b = band(k)
        c = counts.setdefault(b, [0, 0])
        c[0] += 1
        c[1] += k not in app
    summary[f"{fid}>{tid}"] = {"truth": len(rows), "missing": len(missing), "bands": counts}
    lines.append(f"\n## {o} > {d}: {len(rows)} trains in 6 h, app misses {len(missing)}  "
                 + "  ".join(f"{b}: {c[1]}/{c[0]} missed" for b, c in sorted(counts.items())))
    for k, v in rows:
        mark = "MISSED" if k not in app else "ok"
        lines.append(f"- {mark:6} {v['dep']:>8} train {v['train']:>5} arr {v['arr']:>8} legs {'+'.join(v['legs'])}"
                     + (f" via {', '.join(v['via'])}" if v['via'] else ""))
lines.insert(4, f"- Itineraries per lookup: {dict(sorted(sizes.items()))}")
json.dump({"summary": summary, "boards": boards}, open(os.path.join(OUT, "coverage.json"), "w"), indent=1)
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))
