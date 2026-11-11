#!/usr/bin/env bash
# api-verify.sh — Verify mutations took effect via GAQL queries
#
# Usage:
#   source lib/api-verify.sh
#   verify_negative_exists "$customer_id" "$campaign_name" "$keyword_text" "$match_type"
#   verify_keyword_paused "$customer_id" "$campaign_name" "$keyword_text"
#   verify_adgroup_paused "$customer_id" "$campaign_name" "$adgroup_name"
#
# All functions return JSON: {"verified": true/false, "detail": "..."}
# Uses GAQL via the REST searchStream endpoint (no MCP dependency).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# API version and base URL come from config.sh (sourced by token-refresh.sh)
# GADS_API_VERSION and GADS_API_BASE are already set

# Run a GAQL query via searchStream
# No developer-token header: tokens were sunset 2026-09-09 and the header is
# ignored by the API servers. Access is granted by the Cloud project that owns
# the OAuth credentials.
_gaql_query() {
  local customer_id="$1"
  local query="$2"
  local access_token
  access_token=$(get_access_token)

  local payload
  payload=$(jq -n --arg q "$query" '{"query": $q}')

  local url="${GADS_API_BASE}/customers/${customer_id}/googleAds:searchStream"

  local -a headers=(-H "Authorization: Bearer ${access_token}" -H "Content-Type: application/json")
  if [ "${GADS_SEND_DEVELOPER_TOKEN:-false}" = "true" ] && [ -n "${GOOGLE_ADS_DEVELOPER_TOKEN:-}" ]; then
    headers+=(-H "developer-token: ${GOOGLE_ADS_DEVELOPER_TOKEN}")
  fi
  if [ -n "${GOOGLE_ADS_LOGIN_CUSTOMER_ID:-}" ]; then
    headers+=(-H "login-customer-id: ${GOOGLE_ADS_LOGIN_CUSTOMER_ID}")
  fi
  # Each array entry is a complete curl argument pair.

  curl -s -X POST "$url" "${headers[@]}" -d "$payload"
}

# ═══════════════════════════════════════════════════════════
# VERIFY: Negative keyword exists at campaign level
# ═══════════════════════════════════════════════════════════
verify_negative_exists() {
  local customer_id="$1"
  local campaign_name="$2"
  local keyword_text="$3"
  local match_type="$4"

  match_type=$(echo "$match_type" | tr '[:lower:]' '[:upper:]')

  # Escape single quotes for GAQL safety
  local safe_campaign safe_keyword
  safe_campaign=$(_gaql_escape "$campaign_name")
  safe_keyword=$(_gaql_escape "$keyword_text")

  local query="SELECT
    campaign.name,
    campaign_criterion.keyword.text,
    campaign_criterion.keyword.match_type,
    campaign_criterion.negative
  FROM campaign_criterion
  WHERE campaign_criterion.negative = TRUE
    AND campaign_criterion.type = 'KEYWORD'
    AND campaign.name = '${safe_campaign}'
    AND campaign_criterion.keyword.text = '${safe_keyword}'
    AND campaign_criterion.keyword.match_type = '${match_type}'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  # searchStream returns an array; check if we got results
  local row_count
  row_count=$(echo "$result" | jq '[.[].results // [] | length] | add // 0' 2>/dev/null)

  if [ "$row_count" -gt 0 ]; then
    jq -n \
      --arg kw "$keyword_text" \
      --arg mt "$match_type" \
      --arg campaign "$campaign_name" \
      '{verified: true, detail: ("Negative keyword \"\($kw)\" [\($mt)] confirmed in campaign \"\($campaign)\"")}'
  else
    jq -n \
      --arg kw "$keyword_text" \
      --arg mt "$match_type" \
      --arg campaign "$campaign_name" \
      '{verified: false, detail: ("Negative keyword \"\($kw)\" [\($mt)] NOT FOUND in campaign \"\($campaign)\"")}'
  fi
}

# ═══════════════════════════════════════════════════════════
# VERIFY: Negative keyword exists at ad group level
# ═══════════════════════════════════════════════════════════
verify_negative_adgroup_exists() {
  local customer_id="$1"
  local campaign_name="$2"
  local adgroup_name="$3"
  local keyword_text="$4"
  local match_type="$5"

  match_type=$(echo "$match_type" | tr '[:lower:]' '[:upper:]')

  local safe_campaign safe_adgroup safe_keyword
  safe_campaign=$(_gaql_escape "$campaign_name")
  safe_adgroup=$(_gaql_escape "$adgroup_name")
  safe_keyword=$(_gaql_escape "$keyword_text")

  local query="SELECT
    campaign.name,
    ad_group.name,
    ad_group_criterion.keyword.text,
    ad_group_criterion.keyword.match_type,
    ad_group_criterion.negative
  FROM ad_group_criterion
  WHERE ad_group_criterion.negative = TRUE
    AND ad_group_criterion.type = 'KEYWORD'
    AND campaign.name = '${safe_campaign}'
    AND ad_group.name = '${safe_adgroup}'
    AND ad_group_criterion.keyword.text = '${safe_keyword}'
    AND ad_group_criterion.keyword.match_type = '${match_type}'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  local row_count
  row_count=$(echo "$result" | jq '[.[].results // [] | length] | add // 0' 2>/dev/null)

  if [ "$row_count" -gt 0 ]; then
    jq -n \
      --arg kw "$keyword_text" \
      --arg mt "$match_type" \
      --arg ag "$adgroup_name" \
      '{verified: true, detail: ("Negative keyword \"\($kw)\" [\($mt)] confirmed in ad group \"\($ag)\"")}'
  else
    jq -n \
      --arg kw "$keyword_text" \
      --arg mt "$match_type" \
      --arg ag "$adgroup_name" \
      '{verified: false, detail: ("Negative keyword \"\($kw)\" [\($mt)] NOT FOUND in ad group \"\($ag)\"")}'
  fi
}

# ═══════════════════════════════════════════════════════════
# VERIFY: Keyword is paused
# ═══════════════════════════════════════════════════════════
verify_keyword_paused() {
  local customer_id="$1"
  local campaign_name="$2"
  local adgroup_name="$3"
  local keyword_text="$4"

  local safe_campaign safe_adgroup safe_keyword
  safe_campaign=$(_gaql_escape "$campaign_name")
  safe_adgroup=$(_gaql_escape "$adgroup_name")
  safe_keyword=$(_gaql_escape "$keyword_text")

  local query="SELECT
    campaign.name,
    ad_group.name,
    ad_group_criterion.keyword.text,
    ad_group_criterion.keyword.match_type,
    ad_group_criterion.status
  FROM keyword_view
  WHERE ad_group_criterion.keyword.text = '${safe_keyword}'
    AND campaign.name = '${safe_campaign}'
    AND ad_group.name = '${safe_adgroup}'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  local status
  status=$(echo "$result" | jq -r '[.[].results[]?.adGroupCriterion.status] | first // "UNKNOWN"' 2>/dev/null)

  if [ "$status" = "PAUSED" ]; then
    jq -n \
      --arg kw "$keyword_text" \
      --arg status "$status" \
      '{verified: true, detail: ("Keyword \"\($kw)\" status is \($status)")}'
  else
    jq -n \
      --arg kw "$keyword_text" \
      --arg status "$status" \
      '{verified: false, detail: ("Keyword \"\($kw)\" status is \($status), expected PAUSED")}'
  fi
}

# ═══════════════════════════════════════════════════════════
# VERIFY: Ad group is paused
# ═══════════════════════════════════════════════════════════
verify_adgroup_paused() {
  local customer_id="$1"
  local campaign_name="$2"
  local adgroup_name="$3"

  local safe_campaign safe_adgroup
  safe_campaign=$(_gaql_escape "$campaign_name")
  safe_adgroup=$(_gaql_escape "$adgroup_name")

  local query="SELECT
    campaign.name,
    ad_group.name,
    ad_group.status
  FROM ad_group
  WHERE ad_group.name = '${safe_adgroup}'
    AND campaign.name = '${safe_campaign}'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  local status
  status=$(echo "$result" | jq -r '[.[].results[]?.adGroup.status] | first // "UNKNOWN"' 2>/dev/null)

  if [ "$status" = "PAUSED" ]; then
    jq -n \
      --arg ag "$adgroup_name" \
      --arg status "$status" \
      '{verified: true, detail: ("Ad group \"\($ag)\" status is \($status)")}'
  else
    jq -n \
      --arg ag "$adgroup_name" \
      --arg status "$status" \
      '{verified: false, detail: ("Ad group \"\($ag)\" status is \($status), expected PAUSED")}'
  fi
}

# ═══════════════════════════════════════════════════════════
# LOOKUP: Resolve campaign name → campaign budget info
# ═══════════════════════════════════════════════════════════
# Returns JSON (or empty string if not found):
# {"budget_resource_name":"customers/.../campaignBudgets/..","current_micros":12345678,"explicitly_shared":false}
lookup_campaign_budget_info() {
  local customer_id="$1"
  local campaign_name="$2"

  local safe_campaign
  safe_campaign=$(_gaql_escape "$campaign_name")

  local query="SELECT
    campaign.name,
    campaign_budget.resource_name,
    campaign_budget.amount_micros,
    campaign_budget.explicitly_shared
  FROM campaign
  WHERE campaign.name = '${safe_campaign}'
    AND campaign.status != 'REMOVED'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  echo "$result" | jq -c '
    [.[].results[]? | {
      budget_resource_name: (.campaignBudget.resourceName // empty),
      current_micros: ((.campaignBudget.amountMicros // 0) | tonumber),
      explicitly_shared: (.campaignBudget.explicitlyShared // false)
    }]
    | map(select(.budget_resource_name != "" and .current_micros > 0))
    | first // empty
  ' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# VERIFY: Campaign budget amount_micros matches expected
# ═══════════════════════════════════════════════════════════
verify_campaign_budget_micros() {
  local customer_id="$1"
  local campaign_name="$2"
  local expected_micros="$3"

  local info
  info=$(lookup_campaign_budget_info "$customer_id" "$campaign_name")

  if [ -z "$info" ]; then
    jq -n \
      --arg campaign "$campaign_name" \
      '{verified: false, detail: ("Campaign budget not found for campaign \"\($campaign)\"")}'
    return 0
  fi

  local got
  got=$(echo "$info" | jq -r '.current_micros')

  if [ "$got" = "$expected_micros" ]; then
    jq -n \
      --arg campaign "$campaign_name" \
      --arg micros "$expected_micros" \
      '{verified: true, detail: ("Budget confirmed for campaign \"\($campaign)\": \($micros) micros")}'
  else
    jq -n \
      --arg campaign "$campaign_name" \
      --arg exp "$expected_micros" \
      --arg got "$got" \
      '{verified: false, detail: ("Budget mismatch for campaign \"\($campaign)\": got=\($got) expected=\($exp) micros")}'
  fi
}

# ═══════════════════════════════════════════════════════════
# LOOKUP: Resolve campaign name → campaign ID
# ═══════════════════════════════════════════════════════════
lookup_campaign_id() {
  local customer_id="$1"
  local campaign_name="$2"

  local safe_name
  safe_name=$(_gaql_escape "$campaign_name")

  local query="SELECT campaign.id, campaign.name FROM campaign WHERE campaign.name = '${safe_name}' AND campaign.status != 'REMOVED'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  echo "$result" | jq -r '[.[].results[]?.campaign.id] | first // empty' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# LOOKUP: Resolve ad group name → ad group ID (within campaign)
# ═══════════════════════════════════════════════════════════
lookup_adgroup_id() {
  local customer_id="$1"
  local campaign_name="$2"
  local adgroup_name="$3"

  local safe_campaign safe_adgroup
  safe_campaign=$(_gaql_escape "$campaign_name")
  safe_adgroup=$(_gaql_escape "$adgroup_name")

  local query="SELECT ad_group.id, ad_group.name, campaign.name FROM ad_group WHERE campaign.name = '${safe_campaign}' AND ad_group.name = '${safe_adgroup}' AND ad_group.status != 'REMOVED'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  echo "$result" | jq -r '[.[].results[]?.adGroup.id] | first // empty' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# LOOKUP: Resolve keyword text → criterion ID (within ad group)
# ═══════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════
# LOOKUP: Resolve ad group name → ad group ID (without campaign name)
# Useful when only the ad group name is known
# ═══════════════════════════════════════════════════════════
lookup_adgroup_id_by_name() {
  local customer_id="$1"
  local adgroup_name="$2"

  local safe_adgroup
  safe_adgroup=$(_gaql_escape "$adgroup_name")

  local query="SELECT ad_group.id, ad_group.name FROM ad_group WHERE ad_group.name = '${safe_adgroup}' AND ad_group.status != 'REMOVED'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  echo "$result" | jq -r '[.[].results[]?.adGroup.id] | first // empty' 2>/dev/null
}

lookup_keyword_criterion_id() {
  local customer_id="$1"
  local campaign_name="$2"
  local adgroup_name="$3"
  local keyword_text="$4"
  local match_type="$5"

  match_type=$(echo "$match_type" | tr '[:lower:]' '[:upper:]')

  local safe_campaign safe_adgroup safe_keyword
  safe_campaign=$(_gaql_escape "$campaign_name")
  safe_adgroup=$(_gaql_escape "$adgroup_name")
  safe_keyword=$(_gaql_escape "$keyword_text")

  local query="SELECT
    ad_group_criterion.criterion_id,
    ad_group_criterion.keyword.text,
    ad_group_criterion.keyword.match_type,
    ad_group.name,
    campaign.name
  FROM keyword_view
  WHERE ad_group_criterion.keyword.text = '${safe_keyword}'
    AND ad_group_criterion.keyword.match_type = '${match_type}'
    AND ad_group.name = '${safe_adgroup}'
    AND campaign.name = '${safe_campaign}'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  echo "$result" | jq -r '[.[].results[]?.adGroupCriterion.criterionId] | first // empty' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# LOOKUP: Resolve ad group → its enabled responsive search ads
# ═══════════════════════════════════════════════════════════
# Returns one JSON object per RSA:
#   { "ad_id": "...", "ad_group_ad_id": "...", "name": "..." }
# The ad_id is what ads:mutate needs (customers/{cid}/ads/{ad_id}).
lookup_rsa_ads_in_adgroup() {
  local customer_id="$1"
  local campaign_name="$2"
  local adgroup_name="$3"

  local safe_campaign safe_adgroup
  safe_campaign=$(_gaql_escape "$campaign_name")
  safe_adgroup=$(_gaql_escape "$adgroup_name")

  local query="SELECT
    ad_group_ad.resource_name,
    ad_group_ad.ad.id,
    ad_group_ad.ad.name,
    ad_group_ad.ad.type,
    ad_group_ad.status
  FROM ad_group_ad
  WHERE ad_group.name = '${safe_adgroup}'
    AND campaign.name = '${safe_campaign}'
    AND ad_group_ad.ad.type = 'RESPONSIVE_SEARCH_AD'
    AND ad_group_ad.status != 'REMOVED'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  # v25 removed ad_group_ad.id — the AdGroupAd id now only appears inside
  # resource_name (customers/{cid}/adGroupAds/{ad_group_id}~{ad_id}), so pull
  # it from there. The ad id is ad_group_ad.ad.id.
  echo "$result" | jq -c '[.[].results[]? | {
    ad_group_ad_id: (.adGroupAd.resourceName | split("/") | last | split("~")[1] // ""),
    ad_group_ad_resource_name: (.adGroupAd.resourceName // ""),
    ad_id: (.adGroupAd.ad.id | tostring),
    name: (.adGroupAd.ad.name // ""),
    type: (.adGroupAd.ad.type // "")
  }]' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# READ: Fetch the live RSA assets (headlines + descriptions + pins)
# ═══════════════════════════════════════════════════════════
# Returns:
#   { "headlines": [{"text":"...","pinned_field":"HEADLINE_1"}],
#     "descriptions": [...],
#     "final_urls": ["https://..."] }
#
# ad_group_ad_asset_view is used (not ad_group_ad.ad.responsive_search_ad)
# because it exposes pinned_field per asset plus the performance label.
# The RSA asset list is the source of truth for what is currently serving.
fetch_rsa_assets() {
  local customer_id="$1"
  local ad_id="$2"

  local query="SELECT
    ad_group_ad.ad.responsive_search_ad.headlines,
    ad_group_ad.ad.responsive_search_ad.descriptions,
    ad_group_ad.ad.final_urls
  FROM ad_group_ad
  WHERE ad_group_ad.ad.id = ${ad_id}
    AND ad_group_ad.ad.type = 'RESPONSIVE_SEARCH_AD'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  local headlines descriptions final_urls
  headlines=$(echo "$result" | jq -c '[.[].results[]?.adGroupAd.ad.responsiveSearchAd.headlines[]? | {text: .text, pinned_field: (.pinnedField // "")}]' 2>/dev/null)
  descriptions=$(echo "$result" | jq -c '[.[].results[]?.adGroupAd.ad.responsiveSearchAd.descriptions[]? | {text: .text, pinned_field: (.pinnedField // "")}]' 2>/dev/null)
  final_urls=$(echo "$result" | jq -c '[.[].results[]?.adGroupAd.ad.finalUrls[]?] | flatten | unique' 2>/dev/null)

  [ -z "$headlines" ] && headlines="[]"
  [ -z "$descriptions" ] && descriptions="[]"
  [ -z "$final_urls" ] && final_urls="[]"

  jq -n \
    --argjson headlines "$headlines" \
    --argjson descriptions "$descriptions" \
    --argjson final_urls "$final_urls" \
    '{headlines: $headlines, descriptions: $descriptions, final_urls: $final_urls}'
}

# ═══════════════════════════════════════════════════════════
# VERIFY: RSA assets now match what the draft asked for
# ═══════════════════════════════════════════════════════════
# Every headline/description in the expected list must be live. Extra live
# assets are tolerated (merge mode adds without removing) but missing ones
# mean the update did not land.
verify_rsa_assets() {
  local customer_id="$1"
  local ad_id="$2"
  local expected_headlines="$3"
  local expected_descriptions="$4"

  local live
  live=$(fetch_rsa_assets "$customer_id" "$ad_id")

  local missing_h missing_d
  missing_h=$(echo "$live" | jq -c --argjson exp "$expected_headlines" '
    [$exp[] | .text] - ([.headlines[].text]) | length')
  missing_d=$(echo "$live" | jq -c --argjson exp "$expected_descriptions" '
    [$exp[] | .text] - ([.descriptions[].text]) | length')

  local live_h_count live_d_count
  live_h_count=$(echo "$live" | jq '.headlines | length')
  live_d_count=$(echo "$live" | jq '.descriptions | length')

  if [ "$missing_h" -eq 0 ] && [ "$missing_d" -eq 0 ]; then
    jq -n --argjson h "$live_h_count" --argjson d "$live_d_count" \
      '{verified: true, detail: ("RSA live: " + ($h|tostring) + " headline(s), " + ($d|tostring) + " description(s)")}'
  else
    jq -n --argjson mh "$missing_h" --argjson md "$missing_d" \
      '{verified: false, detail: ("RSA missing " + ($mh|tostring) + " headline(s), " + ($md|tostring) + " description(s)")}'
  fi
}

# ═══════════════════════════════════════════════════════════
# LOOKUP: Resolve a Performance Max asset group by campaign + name
# ═══════════════════════════════════════════════════════════
# Returns:
#   { "asset_group_id": "...", "name": "...", "final_urls": [...] }
#
# Performance Max campaigns have asset groups, not ad groups. The asset group
# is what carries the final URLs, so it is the PMax equivalent of an ad group.
lookup_asset_group() {
  local customer_id="$1"
  local campaign_name="$2"
  local asset_group_name="$3"

  local safe_campaign safe_ag
  safe_campaign=$(_gaql_escape "$campaign_name")
  safe_ag=$(_gaql_escape "$asset_group_name")

  local query="SELECT
    asset_group.id,
    asset_group.name,
    asset_group.status,
    asset_group.final_urls
  FROM asset_group
  WHERE campaign.name = '${safe_campaign}'
    AND asset_group.name = '${safe_ag}'
    AND asset_group.status != 'REMOVED'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  echo "$result" | jq -c '[.[].results[]? | {
    asset_group_id: (.assetGroup.id | tostring),
    name: (.assetGroup.name // ""),
    status: (.assetGroup.status // ""),
    final_urls: (.assetGroup.finalUrls // [])
  }]' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# READ: Fetch the live text assets of a Performance Max asset group
# ═══════════════════════════════════════════════════════════
# Returns:
#   { "HEADLINE": [{"text":"...","pinned_field":""}],
#     "LONG_HEADLINE": [...],
#     "DESCRIPTION": [...] }
#
# Two calls are needed: the asset_group_asset relation does not expand to the
# asset's text when the asset group is filtered, so we take the asset resource
# names first and then read the assets by id.
fetch_asset_group_text_assets() {
  local customer_id="$1"
  local asset_group_id="$2"

  local query="SELECT
    asset_group_asset.field_type,
    asset_group_asset.status,
    asset_group_asset.asset
  FROM asset_group_asset
  WHERE asset_group.id = ${asset_group_id}
    AND asset_group_asset.status = 'ENABLED'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  local ids
  ids=$(echo "$result" | jq -r '[.[].results[]?.assetGroupAsset.asset | split("/") | last] | unique | join(",")' 2>/dev/null)

  if [ -z "$ids" ]; then
    echo '{"HEADLINE":[],"LONG_HEADLINE":[],"DESCRIPTION":[]}'
    return 0
  fi

  local asset_query
  asset_query="SELECT asset.id, asset.text_asset.text FROM asset WHERE asset.id IN (${ids})"

  local assets
  assets=$(_gaql_query "$customer_id" "$asset_query")

  # Join the two result sets by asset id.
  echo "$result" | jq -c --argjson assets "$(echo "$assets" | jq -c '[.[].results[]?.asset | {id: (.id|tostring), text: (.textAsset.text // "")}]' 2>/dev/null)" '
    def byId($id): ($assets | map(select(.id == $id)) | first | .text);
    {
      HEADLINE: [ .[].results[]?.assetGroupAsset
        | select(.fieldType == "HEADLINE")
        | {text: (byId((.asset | split("/") | last)) // ""), pinned_field: ""} ],
      LONG_HEADLINE: [ .[].results[]?.assetGroupAsset
        | select(.fieldType == "LONG_HEADLINE")
        | {text: (byId((.asset | split("/") | last)) // ""), pinned_field: ""} ],
      DESCRIPTION: [ .[].results[]?.assetGroupAsset
        | select(.fieldType == "DESCRIPTION")
        | {text: (byId((.asset | split("/") | last)) // ""), pinned_field: ""} ]
    }' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════
# VERIFY: An extension asset is linked to the ad group
# ═══════════════════════════════════════════════════════════
verify_adgroup_asset_exists() {
  local customer_id="$1"
  local adgroup_name="$2"
  local asset_id="$3"

  local safe_adgroup
  safe_adgroup=$(_gaql_escape "$adgroup_name")

  # v25 removed ad_group_asset.asset.id — the linked asset id now only appears
  # inside ad_group_asset.resource_name
  # (customers/{cid}/adGroupAssets/{ad_group_id}~{asset_id}~{field_type}).
  # ad_group.name must also be selected because it appears in the WHERE clause.
  local query="SELECT ad_group.name, ad_group_asset.resource_name FROM ad_group_asset
    WHERE ad_group.name = '${safe_adgroup}' AND ad_group_asset.asset = 'customers/${customer_id}/assets/${asset_id}'"

  local result
  result=$(_gaql_query "$customer_id" "$query")

  local found
  found=$(echo "$result" | jq -r '[.[].results[]?.adGroupAsset.resourceName] | first // empty' 2>/dev/null)

  if [ -n "$found" ]; then
    jq -n --arg rn "$found" '{verified: true, detail: ("asset linked: " + $rn)}'
  else
    jq -n '{verified: false, detail: "asset not found on ad group"}'
  fi
}
