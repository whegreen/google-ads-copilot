#!/usr/bin/env python3
"""
Fetch campaign summary for the selected customer.
"""
import os
import json
from google.ads.googleads.client import GoogleAdsClient
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials

# Load credentials
CREDENTIALS_PATH = os.path.join(
    os.path.dirname(__file__), "..", "data", "google-ads-adc-authorized-user.json"
)

with open(CREDENTIALS_PATH) as f:
    creds_data = json.load(f)

credentials = Credentials(
    token=None,
    refresh_token=creds_data["refresh_token"],
    client_id=creds_data["client_id"],
    client_secret=creds_data["client_secret"],
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

CUSTOMER_ID = "9432618196"
ga_service = client.get_service("GoogleAdsService")

# Campaign summary query
query = """
    SELECT 
        campaign.id,
        campaign.name,
        campaign.status,
        campaign.advertising_channel_type,
        campaign.bidding_strategy_type
    FROM campaign
    WHERE campaign.status != 'REMOVED'
    ORDER BY campaign.id
"""

print(f"Campaigns for customer {CUSTOMER_ID}:\n")

response = ga_service.search(customer_id=CUSTOMER_ID, query=query)

active_count = 0
paused_count = 0
total_count = 0

for row in response:
    c = row.campaign
    total_count += 1
    status = c.status.name
    if status == "ENABLED":
        active_count += 1
    elif status == "PAUSED":
        paused_count += 1
    
    print(f"  [{status}] {c.name}")
    print(f"    ID: {c.id} | Type: {c.advertising_channel_type.name} | Bidding: {c.bidding_strategy_type.name}")

print(f"\n--- Summary ---")
print(f"Total campaigns: {total_count}")
print(f"  ENABLED: {active_count}")
print(f"  PAUSED: {paused_count}")
print(f"  REMOVED: (excluded)")