#!/usr/bin/env bash
# api-mutate.sh — Execute a single Google Ads API mutation
#
# Usage:
#   source lib/api-mutate.sh
#   result=$(mutate_add_negative "$customer_id" "$campaign_id" "$keyword" "$match_type")
#   result=$(mutate_add_negative_adgroup "$customer_id" "$adgroup_id" "$keyword" "$match_type")
#   result=$(mutate_pause_keyword "$customer_id" "$adgroup_criterion_id")
#   result=$(mutate_pause_adgroup "$customer_id" "$adgroup_id")
#
# All functions return JSON: {"success": true/false, "resource_name": "...", "error": "..."}
# Requires: get_access_token from lib/token-refresh.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# API version and base URL come from config.sh (sourced by token-refresh.sh)
# GADS_API_VERSION and GADS_API_BASE are already set

# Common headers for Google Ads API
# The developer-token header is optional and ignored by the API servers since
# the 2026-09-09 token sunset. Only send it when explicitly asked, because a
# future major version will start rejecting it.
# https://developers.google.com/google-ads/api/docs/api-policy/developer-token
_gads_headers() {
  local access_token="$1"
  # Emits bare "Name: value" lines — the caller turns each into a curl -H
  # argument. Emitting the whole "-H Name: value" string here would make it a
  # single argv entry and curl would treat it as one malformed argument.
  echo "Authorization: Bearer ${access_token}"
  if [ "${GADS_SEND_DEVELOPER_TOKEN:-false}" = "true" ] && [ -n "${GOOGLE_ADS_DEVELOPER_TOKEN:-}" ]; then
    echo "developer-token: ${GOOGLE_ADS_DEVELOPER_TOKEN}"
  fi
  echo "Content-Type: application/json"
  if [ -n "${GOOGLE_ADS_LOGIN_CUSTOMER_ID:-}" ]; then
    echo "login-customer-id: ${GOOGLE_ADS_LOGIN_CUSTOMER_ID}"
  fi
}

# Wrapper: make an API call and return structured result
_gads_call() {
  local method="$1"
  local url="$2"
  local body="$3"
  local access_token
  access_token=$(get_access_token)

  # The header list has to be built before the curl call so the optional
  # developer-token can be included or left out cleanly. Each entry becomes
  # its own curl -H argument.
  local -a headers=()
  while IFS= read -r h; do
    headers+=(-H "$h")
  done < <(_gads_headers "$access_token")

  local response http_code
  response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" \
    "${headers[@]}" \
    -d "$body")

  http_code=$(echo "$response" | tail -1)
  local body_response
  body_response=$(echo "$response" | sed '$d')

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "$body_response"
    return 0
  else
    echo "$body_response" >&2
    return 1
  fi
}

# Wrapper: same call but with "validateOnly": true injected at request level.
# Google Ads validates the whole payload (limits, pins, duplicate text) without
# executing anything — a free dry-run on the server side.
_gads_call_validate_only() {
  local method="$1"
  local url="$2"
  local body="$3"

  local validated
  validated=$(echo "$body" | jq '. + {validateOnly: true}')
  _gads_call "$method" "$url" "$validated"
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Add campaign-level negative keyword
# ═══════════════════════════════════════════════════════════
mutate_add_negative_campaign() {
  local customer_id="$1"      # e.g., 1234567890
  local campaign_id="$2"      # numeric campaign ID
  local keyword_text="$3"     # e.g., "near me"
  local match_type="$4"       # PHRASE, EXACT, or BROAD

  # Normalize match type to uppercase
  match_type=$(echo "$match_type" | tr '[:lower:]' '[:upper:]')

  local payload
  payload=$(jq -n \
    --arg campaign "customers/${customer_id}/campaigns/${campaign_id}" \
    --arg text "$keyword_text" \
    --arg match "$match_type" \
    '{
      "operations": [{
        "create": {
          "campaign": $campaign,
          "negative": true,
          "keyword": {
            "text": $text,
            "matchType": $match
          }
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/campaignCriteria:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    # Extract the resource name from the response
    local resource_name
    resource_name=$(echo "$result" | jq -r '.results[0].resourceName // empty')
    local criterion_id
    criterion_id="${resource_name##*~}"

    jq -n \
      --arg resource_name "$resource_name" \
      --arg criterion_id "$criterion_id" \
      '{success: true, resource_name: $resource_name, criterion_id: $criterion_id}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")

    # Check for duplicate keyword (not really an error)
    if echo "$error_msg" | grep -qi "duplicate"; then
      jq -n --arg msg "$error_msg" '{success: true, already_exists: true, message: $msg}'
    else
      jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
    fi
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Add ad-group-level negative keyword
# ═══════════════════════════════════════════════════════════
mutate_add_negative_adgroup() {
  local customer_id="$1"
  local adgroup_id="$2"
  local keyword_text="$3"
  local match_type="$4"

  match_type=$(echo "$match_type" | tr '[:lower:]' '[:upper:]')

  local payload
  payload=$(jq -n \
    --arg adgroup "customers/${customer_id}/adGroups/${adgroup_id}" \
    --arg text "$keyword_text" \
    --arg match "$match_type" \
    '{
      "operations": [{
        "create": {
          "adGroup": $adgroup,
          "negative": true,
          "keyword": {
            "text": $text,
            "matchType": $match
          }
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/adGroupCriteria:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    local resource_name
    resource_name=$(echo "$result" | jq -r '.results[0].resourceName // empty')
    local criterion_id
    criterion_id="${resource_name##*~}"

    jq -n \
      --arg resource_name "$resource_name" \
      --arg criterion_id "$criterion_id" \
      '{success: true, resource_name: $resource_name, criterion_id: $criterion_id}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    if echo "$error_msg" | grep -qi "duplicate"; then
      jq -n --arg msg "$error_msg" '{success: true, already_exists: true, message: $msg}'
    else
      jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
    fi
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Pause a keyword (ad group criterion)
# ═══════════════════════════════════════════════════════════
mutate_pause_keyword() {
  local customer_id="$1"
  local adgroup_id="$2"
  local criterion_id="$3"

  local resource_name="customers/${customer_id}/adGroupCriteria/${adgroup_id}~${criterion_id}"

  local payload
  payload=$(jq -n \
    --arg rn "$resource_name" \
    '{
      "operations": [{
        "updateMask": "status",
        "update": {
          "resourceName": $rn,
          "status": "PAUSED"
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/adGroupCriteria:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn, new_status: "PAUSED"}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Pause an ad group
# ═══════════════════════════════════════════════════════════
mutate_pause_adgroup() {
  local customer_id="$1"
  local adgroup_id="$2"

  local resource_name="customers/${customer_id}/adGroups/${adgroup_id}"

  local payload
  payload=$(jq -n \
    --arg rn "$resource_name" \
    '{
      "operations": [{
        "updateMask": "status",
        "update": {
          "resourceName": $rn,
          "status": "PAUSED"
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/adGroups:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn, new_status: "PAUSED"}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Set campaign daily budget (campaign budget amountMicros)
# ═══════════════════════════════════════════════════════════
mutate_set_campaign_budget_micros() {
  local customer_id="$1"
  local campaign_budget_resource_name="$2"   # customers/{cid}/campaignBudgets/{budget_id}
  local proposed_micros="$3"                 # integer micros

  local payload
  payload=$(jq -n \
    --arg rn "$campaign_budget_resource_name" \
    --argjson micros "$proposed_micros" \
    '{
      "operations": [{
        "updateMask": "amount_micros",
        "update": {
          "resourceName": $rn,
          "amountMicros": $micros
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/campaignBudgets:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    local resource_name
    resource_name=$(echo "$result" | jq -r '.results[0].resourceName // empty')
    [ -z "$resource_name" ] && resource_name="$campaign_budget_resource_name"
    jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# REVERSAL: Remove a campaign criterion (undo negative keyword)
# ═══════════════════════════════════════════════════════════
mutate_remove_campaign_criterion() {
  local customer_id="$1"
  local resource_name="$2"  # e.g., customers/123/campaignCriteria/campaignId~criterionId

  local payload
  payload=$(jq -n \
    --arg rn "$resource_name" \
    '{
      "operations": [{
        "remove": $rn
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/campaignCriteria:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    jq -n --arg rn "$resource_name" '{success: true, removed: $rn}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# REVERSAL: Remove an ad group criterion (undo negative keyword)
# ═══════════════════════════════════════════════════════════
mutate_remove_adgroup_criterion() {
  local customer_id="$1"
  local resource_name="$2"  # e.g., customers/123/adGroupCriteria/456~789

  local payload
  payload=$(jq -n \
    --arg rn "$resource_name" \
    '{
      "operations": [{
        "remove": $rn
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/adGroupCriteria:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    jq -n --arg rn "$resource_name" '{success: true, removed: $rn}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Update RSA text assets (headlines + descriptions)
# ═══════════════════════════════════════════════════════════
# Update an existing responsive search ad's assets.
#
#   mutate_update_rsa_assets <customer_id> <ad_id> <headlines_json> <descriptions_json> <final_urls_json> [validate_only]
#
# headlines_json / descriptions_json: [{"text":"...","pinned_field":"HEADLINE_1"}]
#   pinned_field may be null/"" (unpinned).
#
# WARNING: the updateMask replaces the ENTIRE headlines and descriptions list.
# The caller must pass the full intended list (existing assets merged with new
# ones). Sending only the new assets would delete everything already serving.
mutate_update_rsa_assets() {
  local customer_id="$1"
  local ad_id="$2"
  local headlines_json="$3"
  local descriptions_json="$4"
  local final_urls_json="$5"
  local validate_only="${6:-false}"

  local ad_rn="customers/${customer_id}/ads/${ad_id}"

  # REST JSON uses camelCase: pinnedField, finalUrls, responsiveSearchAd.
  local payload
  payload=$(jq -n \
    --arg rn "$ad_rn" \
    --argjson headlines "$headlines_json" \
    --argjson descriptions "$descriptions_json" \
    --argjson finalUrls "$final_urls_json" \
    '{
      "operations": [{
        "updateMask": "responsive_search_ad.headlines,responsive_search_ad.descriptions",
        "update": {
          "resourceName": $rn,
          "finalUrls": $finalUrls,
          "responsiveSearchAd": {
            "headlines": ($headlines | map(
              if (.pinned_field // "") == "" then {text: .text}
              else {text: .text, pinnedField: .pinned_field} end)),
            "descriptions": ($descriptions | map(
              if (.pinned_field // "") == "" then {text: .text}
              else {text: .text, pinnedField: .pinned_field} end))
          }
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/ads:mutate"

  local result rc
  if [ "$validate_only" = "true" ]; then
    result=$(_gads_call_validate_only "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  else
    result=$(_gads_call "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    local resource_name
    resource_name=$(echo "$result" | jq -r '.results[0].resourceName // empty')
    [ -z "$resource_name" ] && resource_name="$ad_rn"
    if [ "$validate_only" = "true" ]; then
      jq -n --arg rn "$resource_name" '{success: true, validated: true, resource_name: $rn}'
    else
      jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn}'
    fi
  else
    local error_msg
    error_msg=$(echo "$result" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    [ -z "$error_msg" ] && error_msg="API call failed"
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Create a text asset (Performance Max asset group)
# ═══════════════════════════════════════════════════════════
#   mutate_create_text_asset <customer_id> <text> [validate_only]
#
# A Performance Max asset group holds assets, not ad copies on an ad. Each
# text asset is created first (assets:mutate) and then linked into the asset
# group (mutate_link_asset_group_asset). Returns the new asset resource name.
mutate_create_text_asset() {
  local customer_id="$1"
  local text="$2"
  local validate_only="${3:-false}"

  local payload
  payload=$(jq -n \
    --arg text "$text" \
    '{
      "operations": [{
        "create": {
          "textAsset": { "text": $text }
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/assets:mutate"

  local result rc
  if [ "$validate_only" = "true" ]; then
    result=$(_gads_call_validate_only "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  else
    result=$(_gads_call "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    local resource_name
    resource_name=$(echo "$result" | jq -r '.results[0].resourceName // empty')
    if [ "$validate_only" = "true" ]; then
      jq -n --arg rn "$resource_name" '{success: true, validated: true, resource_name: $rn}'
    else
      jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn}'
    fi
  else
    local error_msg
    error_msg=$(echo "$result" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    [ -z "$error_msg" ] && error_msg="API call failed"
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Link an asset into a Performance Max asset group
# ═══════════════════════════════════════════════════════════
#   mutate_link_asset_group_asset <customer_id> <asset_group_id> <asset_resource_name> <field_type> [validate_only]
#
# field_type is the AssetFieldType: HEADLINE | LONG_HEADLINE | DESCRIPTION.
mutate_link_asset_group_asset() {
  local customer_id="$1"
  local asset_group_id="$2"
  local asset_resource_name="$3"
  local field_type="$4"
  local validate_only="${5:-false}"

  local payload
  payload=$(jq -n \
    --arg ag "customers/${customer_id}/assetGroups/${asset_group_id}" \
    --arg asset "$asset_resource_name" \
    --arg ft "$field_type" \
    '{
      "operations": [{
        "create": {
          "assetGroup": $ag,
          "asset": $asset,
          "fieldType": $ft
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/assetGroupAssets:mutate"

  local result rc
  if [ "$validate_only" = "true" ]; then
    result=$(_gads_call_validate_only "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  else
    result=$(_gads_call "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    local resource_name
    resource_name=$(echo "$result" | jq -r '.results[0].resourceName // empty')
    if [ "$validate_only" = "true" ]; then
      jq -n --arg rn "$resource_name" '{success: true, validated: true, resource_name: $rn}'
    else
      jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn}'
    fi
  else
    local error_msg
    error_msg=$(echo "$result" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    [ -z "$error_msg" ] && error_msg="API call failed"
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Update a Performance Max asset group's final URLs
# ═══════════════════════════════════════════════════════════
#   mutate_set_asset_group_final_urls <customer_id> <asset_group_id> <final_urls_json> [validate_only]
#
# This is where an ad's destination lives in Performance Max — the asset group
# carries the final URLs, not the campaign and not the ad.
mutate_set_asset_group_final_urls() {
  local customer_id="$1"
  local asset_group_id="$2"
  local final_urls_json="$3"
  local validate_only="${4:-false}"

  local payload
  payload=$(jq -n \
    --arg rn "customers/${customer_id}/assetGroups/${asset_group_id}" \
    --argjson urls "$final_urls_json" \
    '{
      "operations": [{
        "updateMask": "final_urls",
        "update": {
          "resourceName": $rn,
          "finalUrls": $urls
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/assetGroups:mutate"

  local result rc
  if [ "$validate_only" = "true" ]; then
    result=$(_gads_call_validate_only "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  else
    result=$(_gads_call "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    local resource_name
    resource_name=$(echo "$result" | jq -r '.results[0].resourceName // empty')
    [ -z "$resource_name" ] && resource_name="customers/${customer_id}/assetGroups/${asset_group_id}"
    if [ "$validate_only" = "true" ]; then
      jq -n --arg rn "$resource_name" '{success: true, validated: true, resource_name: $rn}'
    else
      jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn}'
    fi
  else
    local error_msg
    error_msg=$(echo "$result" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    [ -z "$error_msg" ] && error_msg="API call failed"
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Create an extension asset (sitelink / callout / snippet)
# ═══════════════════════════════════════════════════════════
#   mutate_create_asset <customer_id> <asset_type> <asset_body_json> [validate_only]
#
# asset_body_json is the type-specific body, e.g. for SITELINK:
#   {"name":"...","sitelinkAsset":{"linkText":"...","descriptionLine1":"...",
#    "descriptionLine2":"...","finalUrl":"https://...","startDate":"2026-11-10"}}
#
# Returns the new asset resource name — needed to link it in a second call.
mutate_create_asset() {
  local customer_id="$1"
  local asset_type="$2"
  local asset_body_json="$3"
  local validate_only="${4:-false}"

  local payload
  payload=$(jq -n \
    --arg type "$asset_type" \
    --argjson body "$asset_body_json" \
    '{
      "operations": [{
        "create": ($body + {type: $type})
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/assets:mutate"

  local result rc
  if [ "$validate_only" = "true" ]; then
    result=$(_gads_call_validate_only "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  else
    result=$(_gads_call "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    local resource_name
    resource_name=$(echo "$result" | jq -r '.results[0].resourceName // empty')
    if [ "$validate_only" = "true" ]; then
      jq -n --arg rn "$resource_name" '{success: true, validated: true, resource_name: $rn}'
    else
      jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn}'
    fi
  else
    local error_msg
    error_msg=$(echo "$result" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    [ -z "$error_msg" ] && error_msg="API call failed"
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Link an asset to an ad group
# ═══════════════════════════════════════════════════════════
#   mutate_link_adgroup_asset <customer_id> <adgroup_id> <asset_resource_name> <field_type> [validate_only]
#
# field_type is the AssetFieldType: SITELINK | CALLOUT | STRUCTURED_SNIPPET.
mutate_link_adgroup_asset() {
  local customer_id="$1"
  local adgroup_id="$2"
  local asset_resource_name="$3"
  local field_type="$4"
  local validate_only="${5:-false}"

  local payload
  payload=$(jq -n \
    --arg ag "customers/${customer_id}/adGroups/${adgroup_id}" \
    --arg asset "$asset_resource_name" \
    --arg ft "$field_type" \
    '{
      "operations": [{
        "create": {
          "adGroup": $ag,
          "asset": $asset,
          "fieldType": $ft
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/adGroupAssets:mutate"

  local result rc
  if [ "$validate_only" = "true" ]; then
    result=$(_gads_call_validate_only "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  else
    result=$(_gads_call "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    local resource_name
    resource_name=$(echo "$result" | jq -r '.results[0].resourceName // empty')
    if [ "$validate_only" = "true" ]; then
      jq -n --arg rn "$resource_name" '{success: true, validated: true, resource_name: $rn}'
    else
      jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn}'
    fi
  else
    local error_msg
    error_msg=$(echo "$result" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    [ -z "$error_msg" ] && error_msg="API call failed"
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# REVERSAL: Remove an ad group asset link (undo extension)
# ═══════════════════════════════════════════════════════════
mutate_remove_adgroup_asset() {
  local customer_id="$1"
  local resource_name="$2"  # customers/{cid}/adGroupAssets/{agId}~{assetId}~{fieldType}

  local payload
  payload=$(jq -n \
    --arg rn "$resource_name" \
    '{
      "operations": [{
        "remove": $rn
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/adGroupAssets:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    jq -n --arg rn "$resource_name" '{success: true, removed: $rn}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# REVERSAL: Re-enable a keyword (undo pause)
# ═══════════════════════════════════════════════════════════
mutate_enable_keyword() {
  local customer_id="$1"
  local adgroup_id="$2"
  local criterion_id="$3"

  local resource_name="customers/${customer_id}/adGroupCriteria/${adgroup_id}~${criterion_id}"

  local payload
  payload=$(jq -n \
    --arg rn "$resource_name" \
    '{
      "operations": [{
        "updateMask": "status",
        "update": {
          "resourceName": $rn,
          "status": "ENABLED"
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/adGroupCriteria:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn, new_status: "ENABLED"}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# REVERSAL: Re-enable an ad group (undo pause)
# ═══════════════════════════════════════════════════════════
mutate_enable_adgroup() {
  local customer_id="$1"
  local adgroup_id="$2"

  local resource_name="customers/${customer_id}/adGroups/${adgroup_id}"

  local payload
  payload=$(jq -n \
    --arg rn "$resource_name" \
    '{
      "operations": [{
        "updateMask": "status",
        "update": {
          "resourceName": $rn,
          "status": "ENABLED"
        }
      }]
    }')

  local url="${GADS_API_BASE}/customers/${customer_id}/adGroups:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload"); then
    jq -n --arg rn "$resource_name" '{success: true, resource_name: $rn, new_status: "ENABLED"}'
  else
    local error_msg
    error_msg=$(echo "$result" 2>&1 | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# MUTATION: Bulk update of a Performance Max asset group
# ═══════════════════════════════════════════════════════════
#   mutate_asset_group_bulk <customer_id> <asset_group_id> <assets_json> <remove_json> [validate_only]
#
# assets_json: [{"field_type":"HEADLINE","text":"..."}, ...]  — assets to create+link
# remove_json: [{"field_type":"HEADLINE","resource_name":"customers/.../assetGroupAssets/..."}, ...]
#
# WHY ONE REQUEST: a Performance Max text asset's text is immutable, so adding an
# asset means creating a NEW asset and linking it. Linking has to happen in the
# same request as the creation, because a temporary resource name (assets/-1)
# does not resolve across separate calls — the API answers "Resource was not
# found".
#
# Removals ride in the same request on purpose: the API checks slot limits
# against the asset group's links, so an asset that is being unlinked has to be
# unlinked in the same request for the freed slot to count.
mutate_asset_group_bulk() {
  local customer_id="$1"
  local asset_group_id="$2"
  local assets_json="$3"
  local remove_json="$4"
  local validate_only="${5:-false}"

  local asset_group_rn="customers/${customer_id}/assetGroups/${asset_group_id}"

  # Temporary resource names must be unique inside one request AND must not
  # repeat across requests (the API would treat them as the same asset).
  # A per-call offset keeps them distinct.
  local offset=$(( (RANDOM % 9000) + 1000 ))
  local tmp_index=0
  local tmp_id asset_rn item

  local operations="[]"

  # Removals first: freeing a slot has to be visible to the limit check that
  # runs on the additions in this same request.
  while IFS= read -r rn; do
    [ -z "$rn" ] && continue
    operations=$(echo "$operations" | jq -c --arg rn "$rn" \
      '. + [{assetGroupAssetOperation:{remove:$rn}}]')
  done < <(echo "$remove_json" | jq -r '.[]?.resource_name // empty' 2>/dev/null)

  # Then create + link each new asset.
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    tmp_index=$((tmp_index + 1))
    tmp_id="-$((offset + tmp_index))"
    asset_rn="customers/${customer_id}/assets/${tmp_id}"
    operations=$(echo "$operations" | jq -c \
      --arg arn "$asset_rn" \
      --arg agrn "$asset_group_rn" \
      --argjson item "$item" \
      '. + [
        {assetOperation:{create:{resourceName:$arn, textAsset:{text:$item.text}}}},
        {assetGroupAssetOperation:{create:{assetGroup:$agrn, asset:$arn, fieldType:$item.field_type}}}
      ]')
  done < <(echo "$assets_json" | jq -c '.[]? | select((.text // "") != "")' 2>/dev/null)

  if [ "$(echo "$operations" | jq 'length')" -eq 0 ]; then
    jq -n '{success: false, error: "No asset operations to perform"}'
    return 1
  fi

  local payload
  payload=$(jq -n --argjson ops "$operations" '{mutateOperations:$ops}')

  local url="${GADS_API_BASE}/customers/${customer_id}/googleAds:mutate"

  local result rc
  if [ "$validate_only" = "true" ]; then
    result=$(_gads_call_validate_only "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  else
    result=$(_gads_call "POST" "$url" "$payload" 2>&1) && rc=0 || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    local count
    count=$(echo "$result" | jq '(.mutateOperationResponses // []) | length' 2>/dev/null || echo 0)
    if [ "$validate_only" = "true" ]; then
      jq -n --argjson n "$count" '{success: true, validated: true, operations: $n}'
    else
      jq -n --argjson n "$count" '{success: true, operations: $n}'
    fi
  else
    local error_msg
    error_msg=$(echo "$result" | jq -r '.. | objects | .message? // empty' 2>/dev/null | head -1)
    [ -z "$error_msg" ] && error_msg=$(echo "$result" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "API call failed")
    [ -z "$error_msg" ] && error_msg="API call failed"
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}

# ═══════════════════════════════════════════════════════════
# REVERSAL: Remove asset links from a Performance Max asset group
# ═══════════════════════════════════════════════════════════
#   mutate_asset_group_remove <customer_id> <resource_names_json>
#
# Uses the `remove` operation. An UPDATE with status=REMOVED is rejected by
# the API ("Enum value 'REMOVED' cannot be used"); status=PAUSED is accepted
# but keeps the slot occupied, so removal has to use `remove`.
mutate_asset_group_remove() {
  local customer_id="$1"
  local resource_names_json="$2"

  local operations="[]"
  local rn
  while IFS= read -r rn; do
    [ -z "$rn" ] && continue
    operations=$(echo "$operations" | jq -c --arg rn "$rn" \
      '. + [{assetGroupAssetOperation:{remove:$rn}}]')
  done < <(echo "$resource_names_json" | jq -r '.[]? // empty' 2>/dev/null)

  if [ "$(echo "$operations" | jq 'length')" -eq 0 ]; then
    jq -n '{success: true, removed: 0}'
    return 0
  fi

  local payload
  payload=$(jq -n --argjson ops "$operations" '{mutateOperations:$ops}')

  local url="${GADS_API_BASE}/customers/${customer_id}/googleAds:mutate"

  local result
  if result=$(_gads_call "POST" "$url" "$payload" 2>&1); then
    jq -n --argjson n "$(echo "$operations" | jq 'length')" '{success: true, removed: $n}'
  else
    local error_msg
    error_msg=$(echo "$result" | jq -r '.. | objects | .message? // empty' 2>/dev/null | head -1)
    [ -z "$error_msg" ] && error_msg="API call failed"
    jq -n --arg msg "$error_msg" '{success: false, error: $msg}'
  fi
}
