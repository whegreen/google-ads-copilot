#!/usr/bin/env python3
"""Confirm the live slot usage and contents of a Performance Max asset group.

Gate 6 of the apply-layer v5 plan. Read-only: it queries the account and
prints what is actually linked, so an operator can check the state before a
write and confirm it after one.

Usage:
  python3 scripts/verify-asset-group-assets.py
  python3 scripts/verify-asset-group-assets.py --asset-group 6654057973
  python3 scripts/verify-asset-group-assets.py --expected snapshot.json

--expected takes a JSON file of the shape
  {"HEADLINE": ["text", ...], "LONG_HEADLINE": [...], "DESCRIPTION": [...]}
and exits 1 when the live lists differ from it.

Uses the same two-GAQL-call pattern as
scripts/apply-layer/lib/api-verify.sh:fetch_asset_group_assets — the
asset_group_asset relation does not expand to the asset's text, and GAQL has
no JOIN, so the asset ids are read first and the texts second.
"""
import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CREDS = ROOT / "data" / "google-ads-adc-authorized-user.json"
API = "https://googleads.googleapis.com/v25"
FIELD_TYPES = ("HEADLINE", "LONG_HEADLINE", "DESCRIPTION")

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


def gaql(customer_id, query):
    body = json.dumps({"query": query}).encode()
    r = urllib.request.Request(
        f"{API}/customers/{customer_id}/googleAds:searchStream",
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
    return d[0].get("results", []) if isinstance(d, list) else []


def fetch(customer_id, asset_group_id):
    rows = gaql(
        customer_id,
        "SELECT asset_group_asset.resource_name, asset_group_asset.field_type, "
        "asset_group_asset.status, asset_group_asset.asset "
        "FROM asset_group_asset "
        f"WHERE asset_group_asset.asset_group = "
        f"'customers/{customer_id}/assetGroups/{asset_group_id}'",
    )
    ids = sorted({r["assetGroupAsset"]["asset"].split("/")[-1] for r in rows})
    texts = {}
    if ids:
        for r in gaql(
            customer_id,
            "SELECT asset.id, asset.text_asset.text FROM asset WHERE asset.id IN ("
            + ",".join(ids)
            + ")",
        ):
            a = r["asset"]
            texts[str(a["id"])] = (a.get("textAsset") or {}).get("text") or ""

    live = {ft: [] for ft in FIELD_TYPES}
    totals = {ft: 0 for ft in FIELD_TYPES}
    for r in rows:
        aga = r["assetGroupAsset"]
        ft = aga.get("fieldType", "")
        if ft not in totals:
            continue
        totals[ft] += 1
        if aga.get("status") != "ENABLED":
            continue
        live[ft].append(
            {
                "text": texts.get(aga["asset"].split("/")[-1], ""),
                "asset_id": aga["asset"].split("/")[-1],
                "resource_name": aga.get("resourceName", ""),
            }
        )
    return live, totals


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--customer", default="9432618196")
    p.add_argument("--asset-group", default="6677194808")
    p.add_argument(
        "--expected",
        help="JSON file of expected texts per field type; exit 1 on mismatch",
    )
    args = p.parse_args()

    live, totals = fetch(args.customer, args.asset_group)

    print(f"Asset group {args.asset_group} (customer {args.customer})")
    print(f"\n{'FIELD TYPE':<16} {'ENABLED':>8} {'LINK ROWS':>10}")
    for ft in FIELD_TYPES:
        print(f"{ft:<16} {len(live[ft]):>8} {totals[ft]:>10}")
    removed = {ft: totals[ft] - len(live[ft]) for ft in FIELD_TYPES}
    if any(removed.values()):
        print(
            "  (link rows include REMOVED ones — the API counts those "
            "against the slot limit too: "
            + ", ".join(f"{ft} -{removed[ft]}" for ft in FIELD_TYPES if removed[ft])
            + ")"
        )

    print("\n=== DUPLICATES (same text within a field type) ===")
    dup = False
    for ft in FIELD_TYPES:
        seen = {}
        for row in live[ft]:
            seen[row["text"]] = seen.get(row["text"], 0) + 1
        for text, n in seen.items():
            if n > 1:
                print(f"  {n}x [{ft}] {text}")
                dup = True
    if not dup:
        print("  (none)")

    print("\n=== ENABLED TEXT ASSETS ===")
    for ft in FIELD_TYPES:
        for row in live[ft]:
            print(f"  [{ft}] {row['text']}")

    if args.expected:
        expected = json.loads(Path(args.expected).read_text())
        mismatch = []
        for ft in FIELD_TYPES:
            exp = sorted(expected.get(ft, []))
            got = sorted(r["text"] for r in live[ft])
            if exp != got:
                missing = [t for t in exp if t not in got]
                extra = [t for t in got if t not in exp]
                mismatch.append((ft, missing, extra))
        if mismatch:
            print("\n=== EXPECTED vs LIVE: MISMATCH ===")
            for ft, missing, extra in mismatch:
                for t in missing:
                    print(f"  [{ft}] missing from live: {t}")
                for t in extra:
                    print(f"  [{ft}] live but not expected: {t}")
            return 1
        print("\n=== EXPECTED vs LIVE: MATCH ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
