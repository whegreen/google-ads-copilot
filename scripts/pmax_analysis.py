#!/usr/bin/env python3
"""PMax analysis - corrected queries."""
import os
import json
from google.ads.googleads.client import GoogleAdsClient
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials

CREDENTIALS_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "google-ads-adc-authorized-user.json")
with open(CREDENTIALS_PATH) as f:
    creds_data = json.load(f)

credentials = Credentials(
    token=None, refresh_token=creds_data["refresh_token"],
    client_id=creds_data["client_id"], client_secret=creds_data["client_secret"],
    token_uri=creds_data.get("token_uri", "https://oauth2.googleapis.com/token"),
)
credentials.refresh(Request())
client = GoogleAdsClient(
    credentials=credentials,
    # Developer tokens were sunset 2026-09-09; access now comes from the
    # Cloud project that owns the OAuth credentials. Pass None when unset.
    developer_token=os.environ.get("GOOGLE_ADS_DEVELOPER_TOKEN") or None,
    login_customer_id=os.environ.get("GOOGLE_ADS_LOGIN_CUSTOMER_ID"),
    use_proto_plus=True,
)

CID = "9432618196"
ga = client.get_service("GoogleAdsService")

# Account currency is IDR (customer.currency_code). The old code printed a
# "$" sign, which mislabelled every amount by ~16,000x — "Cost: $330643.68"
# read as a third of a million dollars for a campaign that spent Rp 330.644.
CURRENCY = "IDR"

def run(label, query):
    print(f"\n{'='*60}\n{label}\n{'='*60}")
    try:
        resp = ga.search(customer_id=CID, query=query)
        rows = list(resp)
        if not rows:
            print("(no rows)")
            return []
        return rows
    except Exception as e:
        print(f"ERROR: {e}")
        return []

# 1. PMax campaign performance - simpler query
rows = run("1. PMAX CAMPAIGN PERFORMANCE", """
    SELECT
      campaign.name,
      campaign.id,
      campaign.status,
      campaign.advertising_channel_type,
      campaign.bidding_strategy_type,
      metrics.impressions,
      metrics.clicks,
      metrics.cost_micros,
      metrics.conversions,
      metrics.all_conversions,
      metrics.conversions_value
    FROM campaign
    WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
      AND campaign.status = 'ENABLED'
""")
for r in rows:
    c = r.campaign
    m = r.metrics
    print(f"\n  [{c.status.name}] {c.name} (ID: {c.id})")
    print(f"    Bidding: {c.bidding_strategy_type.name}")
    print(f"    Impressions: {m.impressions} | Clicks: {m.clicks}")
    print(f"    Cost: {CURRENCY} {m.cost_micros/1e6:.2f} | Conversions: {m.conversions} | All Conv: {m.all_conversions}")
    if m.conversions > 0:
        print(f"    Conv Value: {CURRENCY} {m.conversions_value:.2f} | CPA: {CURRENCY} {m.cost_micros/1e6/m.conversions:.2f}")

# 2. Asset group performance
rows = run("2. ASSET GROUP PERFORMANCE", """
    SELECT
      campaign.name,
      asset_group.name,
      asset_group.status,
      asset_group.id,
      metrics.impressions,
      metrics.clicks,
      metrics.cost_micros,
      metrics.conversions
    FROM asset_group
    WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
""")
for r in rows:
    c = r.campaign
    ag = r.asset_group
    m = r.metrics
    print(f"\n  Campaign: {c.name}")
    print(f"  Asset Group: [{ag.status.name}] {ag.name} (ID: {ag.id})")
    print(f"    Impressions: {m.impressions} | Clicks: {m.clicks} | Cost: {CURRENCY} {m.cost_micros/1e6:.2f} | Conv: {m.conversions}")

# 3. Asset group assets
rows = run("3. ASSET GROUP ASSETS", """
    SELECT
      campaign.name,
      asset_group.name,
      asset.text_asset.text,
      asset.type,
      asset_group_asset.field_type,
      asset_group_asset.status
    FROM asset_group_asset
    WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
      AND asset_group_asset.status != 'REMOVED'
    ORDER BY asset_group.name, asset_group_asset.field_type
""")
for r in rows:
    c = r.campaign
    ag = r.asset_group
    a = r.asset
    aga = r.asset_group_asset
    text = a.text_asset.text[:80] if a.text_asset.text else "(non-text)"
    print(f"\n  [{aga.field_type.name}] {text}")
    print(f"    Asset Type: {a.type.name} | Status: {aga.status.name}")

# 4. Audience signals
# v25 removed the asset_group_audience resource — the same data now lives on
# the `audience` resource, which points back at its asset group.
rows = run("4. AUDIENCE SIGNALS", """
    SELECT
      asset_group.name,
      audience.description,
      audience.dimensions
    FROM audience
""")

# 5. Search themes
# REMOVED in the API: the search_theme resource no longer exists in v25/v26
# (confirmed against the official v25 field index). Performance Max search-theme
# visibility is gone — query-level intent analysis is not available for PMax.
print("\n[5. SEARCH THEMES]")
print("  (skipped — the search_theme resource was removed from the API in v25)")
print("  PMax does not expose search themes or search terms; intent analysis for")
print("  PMax campaigns has to be inferred from assets, audience and landing page.")

# 6. PMax query visibility (last 30 days)
rows = run("6. PMAX QUERY VISIBILITY (LAST_30_DAYS)", """
    SELECT
      campaign.name,
      search_term_view.search_term,
      metrics.impressions,
      metrics.clicks,
      metrics.cost_micros,
      metrics.conversions
    FROM search_term_view
    WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
      AND segments.date DURING LAST_30_DAYS
    ORDER BY metrics.cost_micros DESC
    LIMIT 50
""")
if not rows:
    print("  (PMax query rows not available — trying all-time)")
    rows = run("6b. PMAX QUERY VISIBILITY (ALL TIME)", """
        SELECT
          campaign.name,
          search_term_view.search_term,
          metrics.impressions,
          metrics.clicks,
          metrics.cost_micros,
          metrics.conversions
        FROM search_term_view
        WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
        ORDER BY metrics.cost_micros DESC
        LIMIT 50
    """)

# 7. All campaign types comparison
rows = run("7. ALL CAMPAIGN TYPES", """
    SELECT
      campaign.name,
      campaign.advertising_channel_type,
      campaign.status,
      metrics.impressions,
      metrics.clicks,
      metrics.cost_micros,
      metrics.conversions,
      metrics.all_conversions
    FROM campaign
    WHERE campaign.status != 'REMOVED'
    ORDER BY metrics.cost_micros DESC
""")
for r in rows:
    c = r.campaign
    m = r.metrics
    print(f"\n  [{c.status.name}] [{c.advertising_channel_type.name}] {c.name}")
    print(f"    Impr: {m.impressions} | Clicks: {m.clicks} | Cost: {CURRENCY} {m.cost_micros/1e6:.2f}")
    print(f"    Conv: {m.conversions} | All Conv: {m.all_conversions}")

# 8. Campaign criteria (corrected)
rows = run("8. CAMPAIGN CRITERIA (LOCATION)", """
    SELECT
      campaign.name,
      campaign_criterion.location.geo_target_constant,
      campaign_criterion.negative,
      campaign_criterion.status
    FROM campaign_criterion
    WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
      AND campaign_criterion.location.geo_target_constant IS NOT NULL
""")

# 9. Device targeting
# v25 rejects `IS NOT NULL` on an enum field — the valid operators are
# =, !=, IN, NOT IN.
rows = run("9. DEVICE TARGETING", """
    SELECT
      campaign.name,
      campaign_criterion.device.type,
      campaign_criterion.status
    FROM campaign_criterion
    WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
      AND campaign_criterion.device.type IN ('MOBILE', 'TABLET', 'DESKTOP', 'CONNECTED_TV')
""")

# 10. Negative keywords (account level)
# v25 removed the customer_negative_keyword resource; account-level negatives
# now live on customer_negative_criterion.
rows = run("10. NEGATIVE KEYWORDS (ACCOUNT)", """
    SELECT
      customer_negative_criterion.id,
      customer_negative_criterion.type,
      customer_negative_criterion.negative_keyword_list.shared_set
    FROM customer_negative_criterion
""")

print("\n" + "="*60)
print("DONE")
