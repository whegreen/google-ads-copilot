#!/usr/bin/env python3
"""Per-asset Performance Max performance + the F2 measurement scorecard.

Read-only, two jobs in one script because they read the same two GAQL
resources:

1. `--assets` (default) — per-asset impressions/clicks/CTR for an asset
   group, plus the live slot usage against the published PMax caps, plus
   near-duplicate detection between linked texts.

   This is the data the asset decisions are made from. It is what the
   265-day review (2026-11-12) was built on, so it must stay reproducible.

2. `--f2` — the weekly scorecard for the F2 gate: `WA Click` conversions per
   week, the `WA Click rate` (WA clicks ÷ clicks) and the `Clicks to call`
   proxy that the campaign is currently optimising for instead.

   Gate (locked 2026-11-12): WA Click >= 10 conversions in the window AND the
   weekly rate stable for >= 3 consecutive weeks (each week within +/-50% of
   the 4-week mean).

Usage:
    python3 scripts/verify-asset-performance.py
    python3 scripts/verify-asset-performance.py --days 90
    python3 scripts/verify-asset-performance.py --since 2026-02-21 --until 2026-11-12
    python3 scripts/verify-asset-performance.py --f2 --weeks 12

Exit codes:
    0  ran fine (--f2: the gate is met)
    1  --f2 only: the gate is NOT met yet
    2  the API could not be queried

Caveat that matters when reading the numbers: Performance Max attributes one
conversion to several assets at once, so the per-asset conversion column
overlaps and must never be summed. Use impressions and CTR per asset, and the
campaign/asset-group level conversions for outcomes.
"""
import argparse
import datetime
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CREDS = ROOT / "data" / "google-ads-adc-authorized-user.json"
API = "https://googleads.googleapis.com/v25"

# Published PMax asset-group caps
# (developers.google.com/google-ads/api/performance-max/asset-requirements).
CAPS = {"HEADLINE": 15, "LONG_HEADLINE": 5, "DESCRIPTION": 5}
FIELD_TYPES = ("HEADLINE", "LONG_HEADLINE", "DESCRIPTION")

WA_CLICK = "WA Click"
CLICKS_TO_CALL = "Clicks to call"


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


def gaql(customer_id: str, query: str) -> list:
    body = json.dumps({"query": query}).encode()
    r = urllib.request.Request(
        f"{API}/customers/{customer_id}/googleAds:searchStream",
        data=body,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        raw = urllib.request.urlopen(r, timeout=120).read()
    except urllib.error.HTTPError as e:
        raw = e.read()
    d = json.loads(raw)
    if isinstance(d, list) and d and "error" in d[0]:
        errs = d[0]["error"].get("details", [{}])[0].get("errors", [{}])
        raise SystemExit(f"API error: {errs[0].get('message', d[0]['error'])}")
    return d[0].get("results", []) if isinstance(d, list) else []


def fetch_links(customer_id: str, asset_group_id: str) -> list:
    """Every linked asset, including the ones with no impressions.

    The dated query below only returns assets that had metrics on some day, so
    an asset that never served (a long headline, a suppressed description)
    would be invisible — and those are exactly the ones that decide whether
    the group is over the slot cap.
    """
    query = (
        "SELECT asset_group_asset.asset, asset_group_asset.field_type, "
        "asset_group_asset.status FROM asset_group_asset "
        "WHERE asset_group_asset.asset_group = 'customers/"
        + customer_id
        + "/assetGroups/"
        + asset_group_id
        + "'"
    )
    return gaql(customer_id, query)


def fetch_texts(customer_id: str, asset_ids: list) -> dict:
    if not asset_ids:
        return {}
    query = (
        "SELECT asset.id, asset.text_asset.text FROM asset WHERE asset.id IN ("
        + ",".join(asset_ids)
        + ")"
    )
    out = {}
    for r in gaql(customer_id, query):
        a = r["asset"]
        out[str(a["id"])] = (a.get("textAsset") or {}).get("text") or ""
    return out


def asset_rows(customer_id: str, asset_group_id: str, start: str, end: str) -> list:
    """One row per asset per day. The asset_group field takes a full resource
    name — a bare id is rejected as a malformed resource name."""
    query = (
        "SELECT segments.date, asset_group_asset.asset, asset_group_asset.field_type, "
        "asset_group_asset.status, asset.text_asset.text, "
        "metrics.impressions, metrics.clicks, metrics.conversions "
        "FROM asset_group_asset "
        "WHERE asset_group_asset.asset_group = 'customers/"
        + customer_id
        + "/assetGroups/"
        + asset_group_id
        + "' AND segments.date BETWEEN '"
        + start
        + "' AND '"
        + end
        + "'"
    )
    return gaql(customer_id, query)


def weekly_conversion_rows(customer_id: str, campaign_id: str, start: str, end: str) -> list:
    """Conversions per day, split by conversion action.

    `segments.conversion_action_name` cannot be combined with clicks /
    impressions / cost in one query ("unsupported metrics") — the click and
    cost metrics are fetched by a second query and merged by date.
    """
    query = (
        "SELECT segments.date, segments.conversion_action_name, metrics.conversions "
        "FROM campaign WHERE campaign.id = "
        + str(campaign_id)
        + " AND segments.date BETWEEN '"
        + start
        + "' AND '"
        + end
        + "'"
    )
    return gaql(customer_id, query)


def daily_traffic_rows(customer_id: str, campaign_id: str, start: str, end: str) -> list:
    query = (
        "SELECT segments.date, metrics.clicks, metrics.impressions, metrics.cost_micros "
        "FROM campaign WHERE campaign.id = "
        + str(campaign_id)
        + " AND segments.date BETWEEN '"
        + start
        + "' AND '"
        + end
        + "'"
    )
    return gaql(customer_id, query)


def iso_week(d: str) -> str:
    day = datetime.date.fromisoformat(d)
    return str(day - datetime.timedelta(days=day.weekday()))


def jaccard(a: str, b: str) -> float:
    wa = set(a.lower().replace(",", " ").replace(".", " ").split())
    wb = set(b.lower().replace(",", " ").replace(".", " ").split())
    if not wa or not wb:
        return 0.0
    return len(wa & wb) / len(wa | wb)


# ── assets mode ──


def print_assets(customer_id: str, asset_group_id: str, start: str, end: str) -> int:
    rows = asset_rows(customer_id, asset_group_id, start, end)
    agg = defaultdict(
        lambda: {
            "imp": 0,
            "clk": 0,
            "cnv": 0,
            "days": 0,
            "first": None,
            "last": None,
            "text": "",
            "ft": "",
            "st": "",
        }
    )
    for r in rows:
        aga = r.get("assetGroupAsset", {})
        m = r.get("metrics", {})
        d = r.get("segments", {}).get("date", "")
        a = agg[aga.get("asset", "?")]
        a["imp"] += int(m.get("impressions", 0))
        a["clk"] += int(m.get("clicks", 0))
        a["cnv"] += int(m.get("conversions", 0))
        if int(m.get("impressions", 0)) > 0:
            a["days"] += 1
        a["first"] = a["first"] or d
        a["last"] = d
        a["text"] = (r.get("asset", {}).get("textAsset", {}) or {}).get("text", "")
        a["ft"] = aga.get("fieldType", "?")
        a["st"] = aga.get("status", "?")

    # The live link rows — the authoritative slot usage.
    links = fetch_links(customer_id, asset_group_id)
    link_ids = sorted({r["assetGroupAsset"]["asset"].split("/")[-1] for r in links})
    texts = fetch_texts(customer_id, link_ids)
    link_meta = {}
    for r in links:
        aga = r["assetGroupAsset"]
        aid = aga["asset"].split("/")[-1]
        link_meta[aid] = {
            "ft": aga.get("fieldType", "?"),
            "st": aga.get("status", "?"),
            "text": texts.get(aid, ""),
        }

    # Merge: a linked asset with no metrics in the window still belongs in the
    # table (with zeros) — it is exactly the asset that never served.
    for aid, meta in link_meta.items():
        key = "customers/%s/assets/%s" % (customer_id, aid)
        if key not in agg:
            agg[key] = {
                "imp": 0,
                "clk": 0,
                "cnv": 0,
                "days": 0,
                "first": "-",
                "last": "-",
                "text": meta["text"],
                "ft": meta["ft"],
                "st": meta["st"],
            }
        else:
            agg[key]["text"] = agg[key]["text"] or meta["text"]

    print("=" * 92)
    print(f" Asset group {asset_group_id} — per-asset performance {start} .. {end}")
    print("=" * 92)
    print(
        f"   {len(rows):,} asset-day rows · {len(agg)} linked assets "
        f"({len(link_ids)} link rows)\n"
    )

    for ft in FIELD_TYPES:
        items = sorted(
            [(k, v) for k, v in agg.items() if v["ft"] == ft],
            key=lambda kv: -kv[1]["imp"],
        )
        if not items:
            continue
        print(f"── {ft} ──")
        print(
            f"   {'asset id':<14}{'status':<9}{'IMP':>7}{'CLK':>6}{'CTR%':>7}{'CNV*':>5}"
            f"{'days':>5}  {'from':<12}text"
        )
        for k, v in items:
            ctr = (v["clk"] / v["imp"] * 100) if v["imp"] else 0.0
            print(
                f"   {k.split('/')[-1]:<14}{v['st']:<9}{v['imp']:>7}{v['clk']:>6}{ctr:>7.2f}"
                f"{v['cnv']:>5}{v['days']:>5}  {str(v['first']):<12}{v['text'][:42]}"
            )
        print()

    print("* CNV per asset OVERLAPS — one PMax conversion is credited to several")
    print("  assets at once. Never sum this column.\n")

    print("── SLOT USAGE (live = ENABLED) vs PUBLISHED caps ──")
    print(
        "   The published cap is not the enforced one: on this account the API "
        "accepted\n"
        "   16 headline links and 8 description links in this very asset group, "
        "and\n"
        "   rejects the next one with RESOURCE_LIMIT. validateOnly is the only "
        "authority."
    )
    for ft in FIELD_TYPES:
        live = [v for v in link_meta.values() if v["ft"] == ft and v["st"] == "ENABLED"]
        links_ft = [v for v in link_meta.values() if v["ft"] == ft]
        cap = CAPS[ft]
        flag = ""
        if len(links_ft) > cap:
            flag = f"  (above the published cap of {cap})"
        print(
            f"   {ft:<16} enabled={len(live):<3} link rows={len(links_ft):<3} "
            f"published cap={cap:<3}{flag}"
        )

    print("\n── NEAR-DUPLICATE TEXTS among linked assets (word overlap >= 0.40) ──")
    found = False
    for ft in FIELD_TYPES:
        live = [
            (aid, meta)
            for aid, meta in link_meta.items()
            if meta["ft"] == ft and meta["st"] == "ENABLED"
        ]
        for i in range(len(live)):
            for j in range(i + 1, len(live)):
                score = jaccard(live[i][1]["text"], live[j][1]["text"])
                if score >= 0.40:
                    found = True
                    imp_i = agg.get("customers/%s/assets/%s" % (customer_id, live[i][0]), {}).get("imp", 0)
                    imp_j = agg.get("customers/%s/assets/%s" % (customer_id, live[j][0]), {}).get("imp", 0)
                    print(
                        f"   {score:.2f} [{ft}] {live[i][1]['text'][:52]}\n"
                        f"          {'':<{len(ft) + 8}}{live[j][1]['text'][:52]}\n"
                        f"          imp {imp_i} vs {imp_j}"
                    )
    if not found:
        print("   (none)")
    else:
        print(
            "   → PMax suppresses the near-duplicate; the richer variant usually wins."
            "\n     Check the impression split before assuming both are serving."
        )
    return 0


# ── f2 mode ──


def print_f2(customer_id: str, campaign_id: str, weeks: int) -> int:
    end = datetime.date.today()
    start = end - datetime.timedelta(days=weeks * 7 + 10)
    start_s, end_s = start.isoformat(), end.isoformat()
    conv_rows = weekly_conversion_rows(customer_id, campaign_id, start_s, end_s)
    traffic_rows = daily_traffic_rows(customer_id, campaign_id, start_s, end_s)

    w = defaultdict(
        lambda: {"wa": 0, "ctc": 0, "other": 0, "clk": 0, "imp": 0, "cost": 0.0}
    )
    for r in traffic_rows:
        m = r.get("metrics", {})
        v = w[iso_week(r.get("segments", {}).get("date", ""))]
        v["clk"] += int(m.get("clicks", 0))
        v["imp"] += int(m.get("impressions", 0))
        v["cost"] += int(m.get("costMicros", 0)) / 1e6
    for r in conv_rows:
        name = r.get("segments", {}).get("conversionActionName", "")
        c = int(r.get("metrics", {}).get("conversions", 0))
        v = w[iso_week(r.get("segments", {}).get("date", ""))]
        if name == WA_CLICK:
            v["wa"] += c
        elif name == CLICKS_TO_CALL:
            v["ctc"] += c
        else:
            v["other"] += c

    print("=" * 78)
    print(f" F2 scorecard — campaign {campaign_id} · last {weeks} weeks")
    print("=" * 78)
    print(
        f"   {'week':<12}{'IMP':>7}{'CLK':>6}{'cost':>8}{'WA':>5}{'CTC':>5}"
        f"{'WA rate':>9}"
    )
    keys = sorted(w)
    for k in keys:
        v = w[k]
        rate = (v["wa"] / v["clk"] * 100) if v["clk"] else 0.0
        print(
            f"   {k:<12}{v['imp']:>7}{v['clk']:>6}{v['cost']:>8.0f}{v['wa']:>5}"
            f"{v['ctc']:>5}{rate:>8.2f}%"
        )

    total_wa = sum(w[k]["wa"] for k in keys)
    total_clk = sum(w[k]["clk"] for k in keys)
    total_ctc = sum(w[k]["ctc"] for k in keys)
    print(
        f"\n   totals: WA Click={total_wa}  Clicks to call={total_ctc}  clicks={total_clk}"
    )

    # ── gate ──
    print("\n── GATE ──")
    ok_count = total_wa >= 10
    print(
        f"   {'✅' if ok_count else '⏳'} WA Click >= 10 in window: {total_wa}"
        f"   (need 10)"
    )

    rates = []
    for k in keys:
        v = w[k]
        if v["clk"]:
            rates.append((k, v["wa"] / v["clk"]))
    last4 = [r for _, r in rates[-4:]]
    mean4 = (sum(last4) / len(last4)) if last4 else 0.0
    last3 = rates[-3:]
    if total_wa == 0:
        print("   ⏳ rate stability: no WA Click conversions yet at all")
        stable_ok = False
    elif mean4 > 0 and len(last3) == 3:
        stable = all(abs(r - mean4) <= 0.5 * mean4 for _, r in last3)
        detail = ", ".join(f"{k}:{r * 100:.1f}%" for k, r in last3)
        print(
            f"   {'✅' if stable else '⏳'} rate stable >= 3 weeks (4-week mean "
            f"{mean4 * 100:.1f}%): {detail}"
        )
        stable_ok = stable
    else:
        print("   ⏳ rate stability: need 3 weeks that had clicks")
        stable_ok = False

    passed = ok_count and stable_ok
    print(f"\n   {'✅ F2 GATE MET' if passed else '⏳ F2 GATE NOT MET YET'}")
    if not passed:
        print("   → no asset write happens before this gate. See the review doc:")
        print("     ~/.opencode/plan/pmax-asset-performance-review-2026-11-12.md")
    if total_ctc and not total_wa:
        print(
            "   → the campaign is still optimising for 'Clicks to call' only."
            "\n     Publish the GTM tags (scripts/check-gtm-tags.py) to start counting WA Click."
        )
    return 0 if passed else 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--customer", default="9432618196")
    p.add_argument("--asset-group", default="6677194808")
    p.add_argument("--campaign", default="23578413255")
    p.add_argument("--days", type=int, default=30, help="window length for --assets")
    p.add_argument("--since", help="explicit window start (YYYY-MM-DD)")
    p.add_argument("--until", help="explicit window end (YYYY-MM-DD)")
    p.add_argument("--weeks", type=int, default=12, help="window length for --f2")
    p.add_argument("--f2", action="store_true", help="F2 gate scorecard instead")
    args = p.parse_args()

    if args.since and args.until:
        start, end = args.since, args.until
    else:
        end_dt = datetime.date.today()
        start_dt = end_dt - datetime.timedelta(days=args.days)
        start, end = start_dt.isoformat(), end_dt.isoformat()

    if args.f2:
        return print_f2(args.customer, args.campaign, args.weeks)
    return print_assets(args.customer, args.asset_group, start, end)


if __name__ == "__main__":
    raise SystemExit(main())
