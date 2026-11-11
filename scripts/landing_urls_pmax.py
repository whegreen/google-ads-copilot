#!/usr/bin/env python3
"""Landing review - PMax specific: asset group final URLs."""
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

# 1. Asset group final URLs
# v25 renamed final_url → final_urls (repeated) and final_mobile_url → final_mobile_urls.
# campaign.status must also be selected when it appears in the WHERE clause
# (EXPECTED_REFERENCED_FIELD_IN_SELECT_CLAUSE).
rows = run("1. ASSET GROUP FINAL URLs", """
    SELECT
      campaign.name,
      campaign.status,
      asset_group.name,
      asset_group.final_urls,
      asset_group.final_mobile_urls,
      asset_group.status
    FROM asset_group
    WHERE campaign.status = 'ENABLED'
""")
for r in rows:
    c = r.campaign
    ag = r.asset_group
    print(f"\n  Campaign: {c.name}")
    print(f"  Asset Group: [{ag.status.name}] {ag.name}")
    print(f"  Final URL: {ag.final_urls}")
    print(f"  Final Mobile URL: {ag.final_mobile_urls}")

# 2. Campaign final URL suffix
rows = run("2. CAMPAIGN FINAL URL SUFFIX", """
    SELECT
      campaign.name,
      campaign.final_url_suffix
    FROM campaign
    WHERE campaign.status = 'ENABLED'
""")

# 3. All ads (any status)
rows = run("3. ALL ADS (ANY STATUS)", """
    SELECT
      campaign.name,
      ad_group.name,
      ad_group_ad.ad.final_urls,
      ad_group_ad.ad.type,
      ad_group_ad.status
    FROM ad_group_ad
    WHERE campaign.status = 'ENABLED'
    LIMIT 50
""")

# 4. Landing page signals (if available)
# v25: final_url → unexpanded_final_url; http_status and page_fetch_time were
# dropped from landing_page_view (they live on expanded_landing_page_view).
# campaign.status must be selected when it appears in the WHERE clause.
rows = run("4. LANDING PAGE SIGNALS", """
    SELECT
      campaign.name,
      campaign.status,
      landing_page_view.unexpanded_final_url,
      metrics.clicks,
      metrics.impressions
    FROM landing_page_view
    WHERE campaign.status = 'ENABLED'
""")

# 5. Campaign landing page experience
rows = run("5. CAMPAIGN LANDING PAGE EXPERIENCE", """
    SELECT
      campaign.name,
      campaign.status,
      metrics.clicks,
      metrics.impressions,
      metrics.conversions
    FROM campaign
    WHERE campaign.status = 'ENABLED'
""")

print("\n" + "="*60)
print("DONE")
