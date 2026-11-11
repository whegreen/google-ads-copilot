#!/usr/bin/env python3
"""Landing review - get PMax landing page URLs."""
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

# 1. Campaign final URL (not suffix)
# v25 dropped campaign.final_url and campaign.display_url entirely — the
# advertiser-specified URLs now live on the asset group (asset_group.final_urls)
# and in landing_page_view.unexpanded_final_url.
rows = run("1. CAMPAIGN FINAL URL", """
    SELECT
      campaign.name,
      campaign.final_url_suffix,
      campaign.status
    FROM campaign
    WHERE campaign.status = 'ENABLED'
""")

# 2. Asset group (just id and name, no URL fields)
rows = run("2. ASSET GROUPS", """
    SELECT
      campaign.name,
      asset_group.name,
      asset_group.id,
      asset_group.status
    FROM asset_group
    WHERE campaign.status = 'ENABLED'
""")

# 3. Check if there are any RSA ads in PMax (shouldn't be, but check)
rows = run("3. RSA ADS", """
    SELECT
      campaign.name,
      ad_group.name,
      ad_group_ad.ad.type,
      ad_group_ad.ad.responsive_search_ad.headlines,
      ad_group_ad.ad.responsive_search_ad.descriptions,
      ad_group_ad.ad.final_urls,
      ad_group_ad.status
    FROM ad_group_ad
    WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
    LIMIT 10
""")

# 4. Try to get landing page from campaign criteria (final URL)
# v25 dropped campaign_criterion.final_url — use landing_page_view instead.
rows = run("4. CAMPAIGN CRITERIA - FINAL URL", """
    SELECT
      campaign.name,
      campaign_criterion.negative
    FROM campaign_criterion
    WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
""")

# 5. All campaign criteria
rows = run("5. ALL CAMPAIGN CRITERIA", """
    SELECT
      campaign.name,
      campaign_criterion.negative,
      campaign_criterion.location.geo_target_constant,
      campaign_criterion.device.type,
      campaign_criterion.keyword.text,
      campaign_criterion.keyword.match_type
    FROM campaign_criterion
    WHERE campaign.advertising_channel_type = 'PERFORMANCE_MAX'
""")

print("\n" + "="*60)
print("DONE")
