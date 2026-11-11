#!/usr/bin/env python3
"""Landing review - simpler queries to find landing page URLs."""
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

# 1. All campaigns (any status)
rows = run("1. ALL CAMPAIGNS", """
    SELECT
      campaign.name,
      campaign.id,
      campaign.status,
      campaign.advertising_channel_type,
      campaign.final_url_suffix
    FROM campaign
""")
for r in rows:
    c = r.campaign
    print(f"  [{c.status.name}] [{c.advertising_channel_type.name}] {c.name} (ID: {c.id})")
    print(f"    Final URL Suffix: {c.final_url_suffix}")

# 2. All asset groups (any status)
rows = run("2. ALL ASSET GROUPS", """
    SELECT
      campaign.name,
      asset_group.name,
      asset_group.id,
      asset_group.status
    FROM asset_group
""")
for r in rows:
    c = r.campaign
    ag = r.asset_group
    print(f"  Campaign: {c.name}")
    print(f"  Asset Group: [{ag.status.name}] {ag.name} (ID: {ag.id})")

# 3. Try to get landing page from ad_group_ad (any status, any type)
rows = run("3. ALL AD GROUP ADS", """
    SELECT
      campaign.name,
      ad_group.name,
      ad_group_ad.ad.type,
      ad_group_ad.ad.final_urls,
      ad_group_ad.status
    FROM ad_group_ad
    LIMIT 20
""")
for r in rows:
    c = r.campaign
    ag = r.ad_group
    ad = r.ad_group_ad
    urls = list(ad.ad.final_urls) if ad.ad.final_urls else []
    print(f"  Campaign: {c.name}")
    print(f"  Ad Group: {ag.name}")
    print(f"  Ad Type: {ad.ad.type.name} | Status: {ad.status.name}")
    print(f"  Final URLs: {urls}")

# 4. Campaign criteria (any)
rows = run("4. CAMPAIGN CRITERIA", """
    SELECT
      campaign.name,
      campaign_criterion.negative
    FROM campaign_criterion
    LIMIT 20
""")
for r in rows:
    c = r.campaign
    cc = r.campaign_criterion
    print(f"  Campaign: {c.name} | Negative: {cc.negative}")

print("\n" + "="*60)
print("DONE")
