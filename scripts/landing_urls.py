#!/usr/bin/env python3
"""Landing review: get ad final URLs and campaign landing page data."""
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

# 1. Ad final URLs (landing pages)
rows = run("1. AD FINAL URLs (ENABLED ADS)", """
    SELECT
      campaign.name,
      ad_group.name,
      ad_group_ad.ad.final_urls,
      ad_group_ad.ad.type,
      ad_group_ad.status,
      metrics.clicks,
      metrics.impressions,
      metrics.conversions,
      metrics.cost_micros
    FROM ad_group_ad
    WHERE campaign.status = 'ENABLED'
      AND ad_group_ad.status = 'ENABLED'
    ORDER BY metrics.clicks DESC
    LIMIT 50
""")
for r in rows:
    c = r.campaign
    ag = r.ad_group
    ad = r.ad_group_ad
    m = r.metrics
    urls = list(ad.ad.final_urls) if ad.ad.final_urls else []
    print(f"\n  Campaign: {c.name}")
    print(f"  Ad Group: {ag.name}")
    print(f"  Ad Type: {ad.ad.type.name} | Status: {ad.status.name}")
    print(f"  Final URLs: {urls}")
    print(f"  Clicks: {m.clicks} | Impr: {m.impressions} | Conv: {m.conversions}")

# 2. Campaign final URL suffix (tracking parameters)
# v25 dropped campaign.display_url.
rows = run("2. CAMPAIGN FINAL URL SUFFIX", """
    SELECT
      campaign.name,
      campaign.final_url_suffix
    FROM campaign
    WHERE campaign.status = 'ENABLED'
""")

# 3. Ad group final URL suffix
rows = run("3. AD GROUP FINAL URL SUFFIX", """
    SELECT
      campaign.name,
      ad_group.name,
      ad_group.final_url_suffix
    FROM ad_group
    WHERE campaign.status = 'ENABLED'
      AND ad_group.status = 'ENABLED'
""")

# 4. Landing page experience (quality score)
rows = run("4. LANDING PAGE EXPERIENCE (QUALITY SCORE)", """
    SELECT
      campaign.name,
      ad_group.name,
      ad_group_criterion.keyword.text,
      ad_group_criterion.quality_info.quality_score,
      ad_group_criterion.quality_info.post_click_quality_score,
      ad_group_criterion.quality_info.creative_quality_score,
      ad_group_criterion.quality_info.search_predicted_ctr
    FROM keyword_view
    WHERE campaign.status = 'ENABLED'
      AND ad_group.status = 'ENABLED'
      AND ad_group_criterion.status = 'ENABLED'
    ORDER BY ad_group_criterion.quality_info.post_click_quality_score ASC
    LIMIT 50
""")

print("\n" + "="*60)
print("DONE")
