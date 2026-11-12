#!/usr/bin/env python3
"""Tracking diagnostic: conversion actions, volume, duplicates, campaign metrics."""
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
# "$" sign, which mislabelled every amount by ~16,000x.
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

# 1. Auto-tagging
rows = run("1. AUTO-TAGGING", """
    SELECT customer.id, customer.descriptive_name, customer.auto_tagging_enabled, customer.currency_code, customer.time_zone
    FROM customer
""")
for r in rows:
    c = r.customer
    print(f"  Auto-tagging: {'ENABLED' if c.auto_tagging_enabled else 'DISABLED'}")
    print(f"  Currency: {c.currency_code} | TZ: {c.time_zone}")

# 2. Conversion action configuration
rows = run("2. CONVERSION ACTIONS (ENABLED)", """
    SELECT
      conversion_action.id,
      conversion_action.name,
      conversion_action.type,
      conversion_action.category,
      conversion_action.status,
      conversion_action.counting_type,
      conversion_action.include_in_conversions_metric,
      conversion_action.value_settings.default_value
    FROM conversion_action
    WHERE conversion_action.status = 'ENABLED'
    ORDER BY conversion_action.id
""")
conv_actions = []
for r in rows:
    ca = r.conversion_action
    conv_actions.append(ca)
    print(f"\n  [{ca.id}] {ca.name}")
    print(f"    Type: {ca.type.name} | Category: {ca.category.name}")
    print(f"    Counting: {ca.counting_type.name} | Primary(include in conv): {ca.include_in_conversions_metric}")
    print(f"    Default value: {ca.value_settings.default_value}")

# 3. Conversion performance by action (30d)
# v25 rejects metrics on the conversion_action resource
# (PROHIBITED_METRIC_IN_SELECT_OR_WHERE_CLAUSE), so the per-action stats have
# to come from a resource that supports both. Query the inventory here and the
# performance from the campaign breakdown below.
rows = run("3. CONVERSION ACTIONS (INVENTORY)", """
    SELECT
      conversion_action.name,
      conversion_action.type,
      conversion_action.status
    FROM conversion_action
    WHERE conversion_action.status = 'ENABLED'
""")

# 4. Campaign-level conversion metrics
rows = run("4. CAMPAIGN METRICS (LAST_30_DAYS)", """
    SELECT
      campaign.name,
      campaign.status,
      metrics.conversions,
      metrics.all_conversions,
      metrics.conversions_value,
      metrics.cost_micros,
      metrics.cost_per_conversion,
      metrics.impressions,
      metrics.clicks,
      metrics.conversions_from_interactions_rate
    FROM campaign
    WHERE campaign.status != 'REMOVED'
      AND segments.date DURING LAST_30_DAYS
    ORDER BY metrics.cost_micros DESC
""")
if not rows:
    print("  (no data in 30d — trying all-time)")
    rows = run("4b. CAMPAIGN METRICS (ALL TIME)", """
        SELECT
          campaign.name, campaign.status,
          metrics.conversions, metrics.all_conversions, metrics.conversions_value,
          metrics.cost_micros, metrics.cost_per_conversion,
          metrics.impressions, metrics.clicks
        FROM campaign
        WHERE campaign.status != 'REMOVED'
        ORDER BY metrics.cost_micros DESC
    """)
for r in rows:
    c = r.campaign
    m = r.metrics
    print(f"\n  [{c.status.name}] {c.name}")
    print(f"    cost: {CURRENCY} {m.cost_micros/1e6:.2f} | impressions: {m.impressions} | clicks: {m.clicks}")
    cpa = f" | CPA: {CURRENCY} {m.cost_per_conversion:.2f}" if m.cost_per_conversion and m.cost_per_conversion > 0 else ""
    print(f"    conversions: {m.conversions} | all_conv: {m.all_conversions} | conv_value: {m.conversions_value}{cpa}")

# 5. Conversion action configuration (all time)
# v25 rejects metrics on the conversion_action resource, so configuration is
# listed here and performance comes from the campaign breakdown above.
rows = run("5. CONVERSION ACTIONS CONFIGURATION", """
    SELECT
      conversion_action.name,
      conversion_action.type,
      conversion_action.counting_type,
      conversion_action.include_in_conversions_metric
    FROM conversion_action
    WHERE conversion_action.status = 'ENABLED'
""")

# 6. Conversion action stats by type (to find duplicates)
rows = run("6. CONVERSION ACTION STATS (30D)", """
    SELECT
      conversion_action.name,
      conversion_action.type,
      conversion_action.counting_type,
      conversion_action.include_in_conversions_metric
    FROM conversion_action
    WHERE segments.date DURING LAST_30_DAYS
      AND conversion_action.status = 'ENABLED'
""")

# 7. All conversion actions (including disabled) to find potential duplicates
rows = run("7. ALL CONVERSION ACTIONS (ANY STATUS)", """
    SELECT
      conversion_action.id,
      conversion_action.name,
      conversion_action.type,
      conversion_action.status,
      conversion_action.counting_type,
      conversion_action.include_in_conversions_metric
    FROM conversion_action
    ORDER BY conversion_action.name
""")

print("\n" + "="*60)
print("DONE")
