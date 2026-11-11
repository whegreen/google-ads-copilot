#!/usr/bin/env python3
"""Asset group inventory + duplicate analysis for the live account.

Read-only. Uses the same two-call pattern as
scripts/apply-layer/lib/api-verify.sh:fetch_asset_group_text_assets.
"""
import json
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CREDS = ROOT / "data" / "google-ads-adc-authorized-user.json"
CID = "9432618196"
API = "https://googleads.googleapis.com/v25"

creds = json.loads(CREDS.read_text())
req = urllib.request.Request(
    "https://oauth2.googleapis.com/token",
    data=urllib.parse.urlencode(
        {
            "client_id": creds["client_id"],
            "client_secret": creds["client_secret"],
            "refresh_token": creds["refresh_token"],
            "grant_type": "refresh_token",
        }
    ).encode(),
    headers={"Content-Type": "application/x-www-form-urlencoded"},
)
token = json.loads(urllib.request.urlopen(req, timeout=30).read())["access_token"]


def gaql(query):
    body = json.dumps({"query": query}).encode()
    r = urllib.request.Request(
        f"{API}/customers/{CID}/googleAds:searchStream",
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        raw = urllib.request.urlopen(r, timeout=40).read()
    except urllib.error.HTTPError as e:
        raw = e.read()
    d = json.loads(raw)
    if isinstance(d, list) and d and "error" in d[0]:
        errs = d[0]["error"].get("details", [{}])[0].get("errors", [{}])
        raise SystemExit(f"API error: {errs[0].get('message', d[0]['error'])}")
    return d[0].get("results", [])


AG_ID = "6677194808"

rows = gaql(
    "SELECT asset_group_asset.field_type, asset_group_asset.status, "
    f"asset_group_asset.asset FROM asset_group_asset WHERE asset_group.id = {AG_ID}"
)

ids = sorted({r["assetGroupAsset"]["asset"].split("/")[-1] for r in rows})
assets = {}
if ids:
    for r in gaql(
        "SELECT asset.id, asset.text_asset.text FROM asset WHERE asset.id IN ("
        + ",".join(ids)
        + ")"
    ):
        a = r["asset"]
        assets[str(a["id"])] = (a.get("textAsset") or {}).get("text") or ""

by_type = {}
counts = Counter()
for r in rows:
    aga = r["assetGroupAsset"]
    if aga.get("status") != "ENABLED":
        continue
    ft = aga["fieldType"]
    counts[ft] += 1
    text = assets.get(aga["asset"].split("/")[-1], "")
    if text:
        by_type.setdefault(ft, []).append(text)

print("=== ENABLED assets per field_type ===")
for ft, n in sorted(counts.items()):
    print(f"  {ft}: {n}")

print("\n=== DUPLICATES (same text within a field type) ===")
dup_found = False
for ft, texts in sorted(by_type.items()):
    for text, n in Counter(texts).items():
        if n > 1:
            print(f"  {n}x [{ft}] {text}")
            dup_found = True
if not dup_found:
    print("  (none)")

print("\n=== TEXT ASSETS ===")
for ft in ("HEADLINE", "LONG_HEADLINE", "DESCRIPTION"):
    for t in sorted(by_type.get(ft, [])):
        print(f"  [{ft}] {t}")

print("\n=== LANGUAGE MIX (text assets) ===")
allt = [t for v in by_type.values() for t in v]
id_count = sum(1 for t in allt if any(w in t.lower() for w in (" dan ", " yang ", " di ", " untuk ")))
print(f"  total text assets: {len(allt)} | contains Indonesian stopwords: {id_count}")
