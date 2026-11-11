#!/usr/bin/env python3
"""Verify that the WA Click conversion action is live and receiving data.

Read-only. Checks:
  1. The `WA Click` conversion action exists, is enabled, and is primary.
  2. Whether it has recorded any conversions (all-time and last 7 days).

Usage:
    python3 scripts/verify-wa-click.py

Note: the data can lag by up to ~30 minutes for GAQL, and the Google Ads UI
can lag further. A zero result right after installing the GTM tag is normal.
"""
import json
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CREDS = ROOT / "data" / "google-ads-adc-authorized-user.json"
CID = "9432618196"
API = "https://googleads.googleapis.com/v25"
ACTION_NAME = "WA Click"


def get_token() -> str:
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
    return json.loads(urllib.request.urlopen(req, timeout=30).read())["access_token"]


TOKEN = get_token()


def gaql(query: str):
    body = json.dumps({"query": query}).encode()
    r = urllib.request.Request(
        f"{API}/customers/{CID}/googleAds:searchStream",
        data=body,
        headers={
            "Authorization": f"Bearer {TOKEN}",
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


def main() -> int:
    print("=" * 62)
    print(f" WA Click conversion action — account {CID}")
    print("=" * 62)

    # ── 1. the action itself ──
    rows = gaql(
        "SELECT conversion_action.id, conversion_action.name, "
        "conversion_action.type, conversion_action.category, "
        "conversion_action.status, conversion_action.include_in_conversions_metric, "
        "conversion_action.primary_for_goal, conversion_action.counting_type "
        "FROM conversion_action "
        f"WHERE conversion_action.name = '{ACTION_NAME}'"
    )
    if not rows:
        print(f"\n❌ No conversion action named '{ACTION_NAME}'.")
        print("   Create it before installing the GTM tag.")
        return 1

    ca = rows[0]["conversionAction"]
    print(f"\n✅ Conversion action found")
    print(f"   id            {ca['id']}")
    print(f"   name          {ca['name']}")
    print(f"   type          {ca['type']}")
    print(f"   category      {ca['category']}")
    print(f"   status        {ca['status']}")
    print(f"   primary goal  {ca.get('primaryForGoal')}")
    print(f"   in metric     {ca.get('includeInConversionsMetric')}")
    print(f"   counting      {ca.get('countingType')}")

    problems = []
    if ca["status"] != "ENABLED":
        problems.append(f"status is {ca['status']}, not ENABLED")
    if not ca.get("primaryForGoal"):
        problems.append("not primary for goal — smart bidding will ignore it")
    if not ca.get("includeInConversionsMetric"):
        problems.append("not included in the All conversions metric")

    # ── 2. has it received conversions ──
    # conversion_action cannot be combined with metrics in one query (v25
    # PROHIBITED_METRIC_IN_SELECT_OR_WHERE_CLAUSE), so segment by conversion
    # action name from the campaign resource instead.
    for label, rng in (("last 7 days", "LAST_7_DAYS"), ("last 30 days", "LAST_30_DAYS")):
        rows = gaql(
            "SELECT segments.conversion_action_name, metrics.conversions, "
            "metrics.all_conversions "
            "FROM campaign "
            f"WHERE segments.date DURING {rng}"
        )
        hit = None
        for r in rows:
            if r.get("segments", {}).get("conversionActionName") == ACTION_NAME:
                hit = r.get("metrics", {})
                break
        if hit is None:
            print(f"\n⏳ {label}: no row for '{ACTION_NAME}' yet")
            print("   (no conversion recorded in this window)")
        else:
            conv = int(hit.get("conversions", 0))
            allc = int(hit.get("allConversions", 0))
            print(f"\n📊 {label}: {conv} primary conversion(s), {allc} all conversion(s)")
            if conv == 0:
                print("   → tag not firing yet, or too early to tell")

    print()
    if problems:
        print("⚠️  Configuration problems:")
        for p in problems:
            print(f"   • {p}")
        return 1

    print("✅ Conversion action is configured correctly.")
    print("   Next: install the GTM tag (see workspace/ads/gtm-setup-spec.md),")
    print("   and check that the site pushes whatsapp_clicked to dataLayer.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
