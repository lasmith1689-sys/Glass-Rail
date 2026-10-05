#!/usr/bin/env python3
"""Which links open the NJ TRANSIT app: the apple-app-site-association Apple's CDN holds
for NJ Transit's domains, and the app's App Store record."""
import json, os, sys, urllib.request, urllib.error

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)


def get(url):
    req = urllib.request.Request(url, headers={"user-agent": "Mozilla/5.0", "accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:500]
    except Exception as e:
        return 0, str(e)


lines = ["# Links into the NJ TRANSIT app\n"]
for host in ["www.njtransit.com", "njtransit.com", "m.njtransit.com", "mobile.njtransit.com", "app.njtransit.com",
             "tickets.njtransit.com", "portal.njtransit.com"]:
    status, body = get(f"https://app-site-association.cdn-apple.com/a/v1/{host}")
    open(os.path.join(OUT, f"aasa-{host}.json"), "w").write(body)
    lines.append(f"## {host} -> {status}\n```\n{body[:4000]}\n```\n")
status, body = get("https://itunes.apple.com/lookup?id=589549928&country=us")
try:
    r = json.loads(body)["results"][0]
    keep = {k: r.get(k) for k in ["trackName", "bundleId", "version", "currentVersionReleaseDate", "sellerName", "releaseNotes", "minimumOsVersion"]}
except Exception:
    keep = body[:500]
lines.append(f"## App Store lookup -> {status}\n```\n{json.dumps(keep, indent=1)[:3000]}\n```")
open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines))
