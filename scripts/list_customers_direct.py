#!/usr/bin/env python3
"""
Direct Google Ads API call to list accessible customers.
Uses the same auth flow as google-ads-mcp.
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

# Create credentials object
credentials = Credentials(
    token=None,
    refresh_token=creds_data["refresh_token"],
    client_id=creds_data["client_id"],
    client_secret=creds_data["client_secret"],
    token_uri=creds_data.get("token_uri", "https://oauth2.googleapis.com/token"),
)

# Refresh to get access token
credentials.refresh(Request())

# Build Google Ads client
client = GoogleAdsClient(
    credentials=credentials,
    # Developer tokens were sunset 2026-09-09; access now comes from the
    # Cloud project that owns the OAuth credentials. Pass None when unset.
    developer_token=os.environ.get("GOOGLE_ADS_DEVELOPER_TOKEN") or None,
    login_customer_id=os.environ.get("GOOGLE_ADS_LOGIN_CUSTOMER_ID"),
    use_proto_plus=True,
)

# Call list_accessible_customers
customer_service = client.get_service("CustomerService")
accessible = customer_service.list_accessible_customers()

print("Accessible customers:")
for i, resource_name in enumerate(accessible.resource_names, 1):
    # resource_name format: customers/1234567890
    cid = resource_name.split("/")[-1]
    print(f"  {i}. {cid} (resource: {resource_name})")

# Also fetch descriptive names for each
if accessible.resource_names:
    print("\nFetching account details...")
    ga_service = client.get_service("GoogleAdsService")
    
    for resource_name in accessible.resource_names:
        cid = resource_name.split("/")[-1]
        query = f"""
            SELECT customer.id, customer.descriptive_name, customer.currency_code, 
                   customer.time_zone, customer.status, customer.auto_tagging_enabled
            FROM customer
            WHERE customer.id = {cid}
        """
        try:
            response = ga_service.search(customer_id=cid, query=query)
            for row in response:
                c = row.customer
                print(f"\n  Customer ID: {c.id}")
                print(f"  Name: {c.descriptive_name}")
                print(f"  Currency: {c.currency_code}")
                print(f"  Timezone: {c.time_zone}")
                print(f"  Status: {c.status.name}")
                print(f"  Auto-tagging: {'Enabled' if c.auto_tagging_enabled else 'Disabled'}")
        except Exception as e:
            print(f"  Error fetching details for {cid}: {e}")