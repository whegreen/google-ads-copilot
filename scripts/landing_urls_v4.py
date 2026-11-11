#!/usr/bin/env python3
"""Landing review - try to find landing page URL from asset group."""
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

# 1. Try asset_group with final_urls (plural)
rows = run("1. ASSET GROUP FINAL URLS (plural)", """
    SELECT
      campaign.name,
      asset_group.name,
      asset_group.final_urls,
      asset_group.final_mobile_urls
    FROM asset_group
    WHERE campaign.status = 'ENABLED'
""")

# 2. Try to get from ad_group (PMax might have ad groups)
rows = run("2. AD GROUPS", """
    SELECT
      campaign.name,
      ad_group.name,
      ad_group.status
    FROM ad_group
    WHERE campaign.status = 'ENABLED'
""")

# 3. Try campaign with different URL fields
rows = run("3. CAMPAIGN URL FIELDS", """
    SELECT
      campaign.name,
      campaign.final_url_suffix,
      campaign.tracking_url_template,
      campaign.url_custom_parameters
    FROM campaign
    WHERE campaign.status = 'ENABLED'
""")

# 4. Try to get from asset group asset (the actual landing page might be in assets)
# v25: full_size_image_url → full_size.url (the size message nests under a dot),
# and marketing_image_urls was dropped. Filtering on asset.type also breaks the
# implicit asset→asset_group_asset relation, so select the type instead.
rows = run("4. ASSET GROUP ASSETS - URLs", """
    SELECT
      campaign.name,
      asset_group.name,
      asset.image_asset.full_size.url,
      asset.type
    FROM asset_group_asset
    WHERE campaign.status = 'ENABLED'
    LIMIT 10
""")

print("\n" + "="*60)
print("DONE")
