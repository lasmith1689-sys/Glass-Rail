#!/usr/bin/env python3
"""Tickets: what NJ Transit says about Apple Wallet and web tickets, and which links
open the NJ TRANSIT app (its apple-app-site-association)."""
import html, json, os, re, sys, urllib.request, urllib.error

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)
UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"


def get(url):
    req = urllib.request.Request(url, headers={"user-agent": UA, "accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return r.status, r.geturl(), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, url, e.read().decode("utf-8", "replace")
    except Exception as e:
        return 0, url, str(e)


def text(page):
    page = re.sub(r"(?is)<(script|style|noscript)[^>]*>.*?</\1>", " ", page)
    page = re.sub(r"(?i)<br\s*/?>|</(p|li|h[1-6]|div|tr|dt|dd)>", "\n", page)
    page = html.unescape(re.sub(r"<[^>]+>", " ", page))
    return "\n".join(" ".join(l.split()) for l in page.splitlines() if l.strip())


lines = ["# Tickets probe\n"]
pages = ["https://www.njtransit.com/web_ticketing_faqs", "https://www.njtransit.com/app",
         "https://www.njtransit.com/scan", "https://www.njtransit.com/mobile-app-faqs",
         "https://www.njtransit.com/faq/mobile-app", "https://www.njtransit.com/webticketing"]
key = re.compile(r"wallet|apple|google pay|activate|activation|conductor|screenshot|transfer|device|pdf|print|expire|valid", re.I)
for url in pages:
    status, final, body = get(url)
    t = text(body) if status == 200 else body[:300]
    name = re.sub(r"[^a-z0-9]+", "-", url.split("//", 1)[1].lower()).strip("-")
    open(os.path.join(OUT, name + ".txt"), "w").write(t)
    hits = [l for l in t.splitlines() if key.search(l)][:60]
    lines.append(f"## {url} -> {status} {final} ({len(t)} chars)")
    lines += [f"- {h[:400]}" for h in hits]
    lines.append("")

for url in ["https://www.njtransit.com/.well-known/apple-app-site-association",
            "https://njtransit.com/.well-known/apple-app-site-association",
            "https://www.njtransit.com/apple-app-site-association",
            "https://mytix.njtransit.com/.well-known/apple-app-site-association",
            "https://m.njtransit.com/.well-known/apple-app-site-association"]:
    status, final, body = get(url)
    open(os.path.join(OUT, re.sub(r"[^a-z0-9]+", "-", url.split("//", 1)[1].lower()).strip("-") + ".txt"), "w").write(body)
    lines.append(f"## {url} -> {status} {final}\n```\n{body[:3000]}\n```\n")

status, final, body = get("https://apps.apple.com/us/app/nj-transit-mobile-app/id589549928")
t = text(body) if status == 200 else body[:300]
open(os.path.join(OUT, "appstore.txt"), "w").write(t)
lines.append(f"## App Store -> {status}")
lines += [f"- {h[:400]}" for h in t.splitlines() if re.search(r"wallet|ticket|version|what's new|seller|developer", h, re.I)][:40]

open(os.path.join(OUT, "summary.md"), "w").write("\n".join(lines))
print("\n".join(lines)[:20000])
