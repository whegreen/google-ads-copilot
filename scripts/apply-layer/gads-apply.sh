#!/usr/bin/env bash
# gads-apply.sh — Main apply-layer orchestrator
#
# Usage:
#   ./gads-apply.sh <draft-file>               # Full apply flow
#   ./gads-apply.sh --dry-run <draft-file>      # Show dry run only, don't execute
#   ./gads-apply.sh --parse-only <draft-file>   # Parse draft to JSON only
#
# Flow: parse → resolve IDs → dry-run → confirm → execute → verify → audit
#
# Environment:
#   GOOGLE_APPLICATION_CREDENTIALS  — path to OAuth2 credentials JSON
#   GOOGLE_ADS_DEVELOPER_TOKEN      — Google Ads API developer token
#   GOOGLE_ADS_LOGIN_CUSTOMER_ID    — (optional) MCC manager account ID

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load libraries (config.sh loaded transitively via token-refresh.sh)
source "$LIB_DIR/token-refresh.sh"
source "$LIB_DIR/parse-draft.sh"
source "$LIB_DIR/asset-rules.sh"
source "$LIB_DIR/api-mutate.sh"
source "$LIB_DIR/api-verify.sh"
source "$LIB_DIR/audit-write.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════
# Parse arguments
# ═══════════════════════════════════════════════════════════
DRY_RUN_ONLY=false
PARSE_ONLY=false
VALIDATE_ONLY=false
FORCE=false
DRAFT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN_ONLY=true; shift ;;
    --parse-only) PARSE_ONLY=true; shift ;;
    --validate-only) VALIDATE_ONLY=true; shift ;;
    --force)      FORCE=true; shift ;;
    -h|--help)
      echo "Usage: gads-apply.sh [--dry-run|--parse-only|--validate-only] <draft-file>"
      echo ""
      echo "Options:"
      echo "  --dry-run       Show what would change without executing"
      echo "  --parse-only    Parse the draft to JSON and exit"
      echo "  --validate-only Run the draft against the live account with validateOnly (no changes)"
      echo "  --force         Override certain safety blocks (v2: budget cooldown only)"
      echo ""
      echo "The draft file should be a markdown file from workspace/ads/drafts/"
      echo ""
      echo "API version: ${GADS_API_VERSION}"
      exit 0
      ;;
    *)
      DRAFT_FILE="$1"; shift ;;
  esac
done

if [ -z "$DRAFT_FILE" ]; then
  echo -e "${RED}ERROR: No draft file specified${NC}"
  echo "Usage: gads-apply.sh [--dry-run|--parse-only] <draft-file>"
  exit 1
fi

# Resolve relative paths against project root
if [[ "$DRAFT_FILE" != /* ]]; then
  DRAFT_FILE="${PROJECT_ROOT}/${DRAFT_FILE}"
fi

if [ ! -f "$DRAFT_FILE" ]; then
  echo -e "${RED}ERROR: Draft file not found: ${DRAFT_FILE}${NC}"
  exit 1
fi

# ═══════════════════════════════════════════════════════════
# Step 1: Parse the draft
# ═══════════════════════════════════════════════════════════
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Google Ads Copilot — Apply Layer (API ${GADS_API_VERSION})${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Step 1: Parsing draft...${NC}"

PARSED=$(parse_draft "$DRAFT_FILE")
CUSTOMER_ID=$(echo "$PARSED" | jq -r '.customer_id')
CUSTOMER_NAME=$(echo "$PARSED" | jq -r '.customer_name')
ACTION_COUNT=$(echo "$PARSED" | jq -r '.action_count')
DRAFT_STATUS=$(echo "$PARSED" | jq -r '.status')
BUDGET_POLICY=$(echo "$PARSED" | jq -c '.meta.budget_policy // {}')
ALLOW_NET_INCREASE=$(echo "$BUDGET_POLICY" | jq -r '.allow_net_increase // false')
MAX_NET_INCREASE_PCT=$(echo "$BUDGET_POLICY" | jq -r '.max_net_increase_pct // 10')

echo "  Account:  ${CUSTOMER_NAME} (${CUSTOMER_ID})"
echo "  Actions:  ${ACTION_COUNT}"
echo "  Status:   ${DRAFT_STATUS}"

if [ "$ACTION_COUNT" -eq 0 ]; then
  echo -e "${YELLOW}No actions found in draft. Nothing to apply.${NC}"
  exit 0
fi

if $PARSE_ONLY; then
  echo ""
  echo "$PARSED" | jq '.'
  exit 0
fi

WORKSPACE_DIR="${PROJECT_ROOT}/workspace/ads"
ACCOUNT_FILE="${WORKSPACE_DIR}/account.md"
DRAFT_INDEX_FILE="${WORKSPACE_DIR}/drafts/_index.md"
REVERSAL_REGISTRY_FILE="${WORKSPACE_DIR}/audit-trail/reversal-registry.json"

_lower() { tr '[:upper:]' '[:lower:]'; }

_abs_int() {
  local n="$1"
  if [ "$n" -lt 0 ]; then
    echo $(( -1 * n ))
  else
    echo "$n"
  fi
}

_pct_change_int() {
  # Returns a signed integer percent change, rounded to nearest int.
  local current="$1"
  local proposed="$2"
  awk -v c="$current" -v p="$proposed" 'BEGIN {
    if (c <= 0) { print 0; exit }
    pct = ((p - c) / c) * 100.0
    if (pct >= 0) { print int(pct + 0.5) } else { print int(pct - 0.5) }
  }'
}

_last_budget_change_epoch_for_campaign() {
  local campaign_name="$1"
  if [ ! -f "$REVERSAL_REGISTRY_FILE" ]; then
    echo ""
    return 0
  fi

  local last_iso
  last_iso=$(jq -r --arg c "$campaign_name" '
    [.reversals[]? | select(.action == "SET_CAMPAIGN_DAILY_BUDGET" and .campaignName == $c) | .appliedAt]
    | sort
    | last // empty
  ' "$REVERSAL_REGISTRY_FILE" 2>/dev/null)

  if [ -z "$last_iso" ]; then
    echo ""
    return 0
  fi

  gads_epoch_from_iso "$last_iso"
}

_tracking_confidence_ok_for_budgets() {
  if [ ! -f "$ACCOUNT_FILE" ]; then
    return 1
  fi

  local tc
  tc=$(gads_markdown_field "$ACCOUNT_FILE" "Tracking confidence" 2>/dev/null || true)
  tc=$(printf '%s' "$tc" | _lower | tr -d '[]' | awk '{print $1}')

  case "$tc" in
    high|medium) return 0 ;;
    *) return 1 ;;
  esac
}

_has_pending_tracking_drafts() {
  if [ ! -f "$DRAFT_INDEX_FILE" ]; then
    # Fail closed for budget actions: if we can't determine pending tracking work, block.
    return 0
  fi

  # Any "tracking" draft in Proposed or Approved blocks budget applies.
  awk '
    $0 == "## Proposed" { sec = "proposed"; next }
    $0 == "## Approved" { sec = "approved"; next }
    $0 ~ /^## / { sec = ""; next }
    (sec == "proposed" || sec == "approved") && tolower($0) ~ /tracking/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$DRAFT_INDEX_FILE"
}

# ═══════════════════════════════════════════════════════════
# Step 2: Validate & resolve IDs
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}Step 2: Validating and resolving resource IDs...${NC}"

# Budget gating (fail closed unless dry-run).
BUDGET_COUNT=$(echo "$PARSED" | jq '[.actions[] | select(.type == "SET_CAMPAIGN_DAILY_BUDGET")] | length')
if [ "$BUDGET_COUNT" -gt 0 ]; then
  if ! _tracking_confidence_ok_for_budgets; then
    msg="Budget actions blocked: tracking confidence must be Medium/High in workspace/ads/account.md"
    if $DRY_RUN_ONLY; then
      echo -e "${YELLOW}⚠️  ${msg} (dry-run continues)${NC}"
    else
      echo -e "${RED}ERROR: ${msg}${NC}"
      exit 1
    fi
  fi

  if _has_pending_tracking_drafts; then
    msg="Budget actions blocked: pending tracking draft(s) exist in workspace/ads/drafts/_index.md"
    if $DRY_RUN_ONLY; then
      echo -e "${YELLOW}⚠️  ${msg} (dry-run continues)${NC}"
    else
      echo -e "${RED}ERROR: ${msg}${NC}"
      exit 1
    fi
  fi
fi

# Get access token (validates credentials)
ACCESS_TOKEN=$(get_access_token)
echo "  ✅ OAuth2 token acquired"

# Build a resolved actions array with IDs
RESOLVED_ACTIONS="[]"
VALIDATION_ERRORS=0

for i in $(seq 0 $((ACTION_COUNT - 1))); do
  action=$(echo "$PARSED" | jq ".actions[$i]")
  action_type=$(echo "$action" | jq -r '.type')
  campaign_name=$(echo "$action" | jq -r '.campaign')
  keyword=$(echo "$action" | jq -r '.keyword // empty')
  match_type=$(echo "$action" | jq -r '.match_type // empty')
  scope=$(echo "$action" | jq -r '.scope')
  adgroup_name=$(echo "$action" | jq -r '.adgroup // empty')
  proposed_budget_micros=$(echo "$action" | jq -r '.proposed_daily_budget_micros // empty')

  # Resolve campaign ID
  campaign_id=$(lookup_campaign_id "$CUSTOMER_ID" "$campaign_name")
  if [ -z "$campaign_id" ]; then
    echo -e "  ${RED}❌ Campaign not found: \"${campaign_name}\"${NC}"
    action=$(echo "$action" | jq '. + {valid: false, error: "Campaign not found"}')
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
  else
    action=$(echo "$action" | jq --arg cid "$campaign_id" '. + {campaign_id: $cid}')
    echo -e "  ✅ Campaign: \"${campaign_name}\" → ID ${campaign_id}"
  fi

  # Resolve campaign budget info + enforce budget guardrails
  if [ "$action_type" = "SET_CAMPAIGN_DAILY_BUDGET" ]; then
    if [ -z "$proposed_budget_micros" ] || [[ ! "$proposed_budget_micros" =~ ^[0-9]+$ ]]; then
      echo -e "  ${RED}❌ Proposed budget micros missing/invalid for: \"${campaign_name}\"${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Proposed budget micros missing/invalid"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    else
      budget_info=$(lookup_campaign_budget_info "$CUSTOMER_ID" "$campaign_name")
      if [ -z "$budget_info" ]; then
        echo -e "  ${RED}❌ Campaign budget not found: \"${campaign_name}\"${NC}"
        action=$(echo "$action" | jq '. + {valid: false, error: "Campaign budget not found"}')
        VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      else
        current_micros=$(echo "$budget_info" | jq -r '.current_micros')
        budget_rn=$(echo "$budget_info" | jq -r '.budget_resource_name')
        explicitly_shared=$(echo "$budget_info" | jq -r '.explicitly_shared // false')

        if [ "$explicitly_shared" = "true" ]; then
          echo -e "  ${RED}❌ Shared campaign budgets are out of scope: \"${campaign_name}\"${NC}"
          action=$(echo "$action" | jq '. + {valid: false, error: "Shared campaign budget is out of scope"}')
          VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
          RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
          continue
        fi

        delta_micros=$((proposed_budget_micros - current_micros))
        pct_change=$(_pct_change_int "$current_micros" "$proposed_budget_micros")

        action=$(echo "$action" | jq \
          --arg rn "$budget_rn" \
          --argjson cur "$current_micros" \
          --argjson prop "$proposed_budget_micros" \
          --argjson delta "$delta_micros" \
          --argjson pct "$pct_change" \
          '. + {
            campaign_budget_resource_name: $rn,
            current_daily_budget_micros: $cur,
            proposed_daily_budget_micros: $prop,
            budget_delta_micros: $delta,
            budget_pct_change: $pct
          }')

        max_pct=$(echo "$action" | jq -r '.guardrails.max_pct_change // 30')
        cooldown_days=$(echo "$action" | jq -r '.guardrails.cooldown_days // 7')

        pct_abs=$(_abs_int "$pct_change")
        if [ "$pct_abs" -gt "$max_pct" ]; then
          echo -e "  ${RED}❌ Budget change exceeds cap for \"${campaign_name}\": ${pct_change}% (cap ${max_pct}%)${NC}"
          action=$(echo "$action" | jq --arg msg "Budget change exceeds cap (${max_pct}%)" '. + {valid: false, error: $msg}')
          VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
        else
          # No-op guardrail: require at least max(5% of current, 5 units) movement.
          min_abs_pct=$(( (current_micros * 5 + 99) / 100 ))
          min_abs_units=5000000
          min_abs="$min_abs_pct"
          if [ "$min_abs" -lt "$min_abs_units" ]; then
            min_abs="$min_abs_units"
          fi

          delta_abs=$(_abs_int "$delta_micros")
          if [ "$delta_abs" -lt "$min_abs" ]; then
            echo -e "  ${YELLOW}⏭️  Budget change is too small (noop) for \"${campaign_name}\"${NC}"
            action=$(echo "$action" | jq '. + {valid: false, error: "No-op budget change (below min delta)"}')
            VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
          fi

          # Cooldown guardrail: block repeated budget changes to same campaign.
          last_epoch=$(_last_budget_change_epoch_for_campaign "$campaign_name")
          if [ -n "$last_epoch" ]; then
            now_epoch=$(date +%s)
            age_days=$(( (now_epoch - last_epoch) / 86400 ))
            if [ "$age_days" -lt "$cooldown_days" ] && ! $FORCE; then
              echo -e "  ${RED}❌ Budget cooldown violation for \"${campaign_name}\": last change ${age_days}d ago (cooldown ${cooldown_days}d)${NC}"
              action=$(echo "$action" | jq --arg msg "Budget cooldown violation (${cooldown_days}d)" '. + {valid: false, error: $msg}')
              VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
            fi
          fi
        fi
      fi
    fi
  fi

  # Resolve ad group ID if needed
  if [ "$scope" = "AD_GROUP" ] && [ -n "$adgroup_name" ]; then
    adgroup_id=$(lookup_adgroup_id "$CUSTOMER_ID" "$campaign_name" "$adgroup_name")
    if [ -z "$adgroup_id" ]; then
      echo -e "  ${RED}❌ Ad group not found: \"${adgroup_name}\"${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Ad group not found"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    else
      action=$(echo "$action" | jq --arg agid "$adgroup_id" '. + {adgroup_id: $agid}')
    fi
  fi

  # For keyword pause actions, resolve the keyword criterion ID
  if [ "$action_type" = "PAUSE_KEYWORD" ] && [ -n "$adgroup_name" ]; then
    criterion_id=$(lookup_keyword_criterion_id "$CUSTOMER_ID" "$campaign_name" "$adgroup_name" "$keyword" "$match_type")
    if [ -z "$criterion_id" ]; then
      echo -e "  ${RED}❌ Keyword criterion not found: \"${keyword}\" [${match_type}]${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Keyword criterion not found"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    else
      action=$(echo "$action" | jq --arg crit "$criterion_id" '. + {criterion_id: $crit}')
    fi
  fi

  # ─── Asset actions (v3) ───
  # Blast-radius guard: an asset action may only touch an ad group that the
  # draft names explicitly. The manifest carries adgroup_name; we resolve it
  # by name (never by a raw id) so a typo cannot hit an unrelated ad group.
  if [ "$action_type" = "UPDATE_RSA_ASSETS" ]; then
    if [ -z "$adgroup_name" ]; then
      echo -e "  ${RED}❌ RSA asset action must name an ad group${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Ad group not named in draft"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    # Which RSA in this ad group? An ad group can hold several.
    rsa_list=$(lookup_rsa_ads_in_adgroup "$CUSTOMER_ID" "$campaign_name" "$adgroup_name")
    rsa_count=$(echo "$rsa_list" | jq 'length' 2>/dev/null || echo 0)

    if [ "$rsa_count" -eq 0 ]; then
      echo -e "  ${RED}❌ No responsive search ad found in \"${adgroup_name}\"${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "No RSA found in ad group"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    if [ "$rsa_count" -gt 1 ]; then
      echo -e "  ${RED}❌ Ad group \"${adgroup_name}\" has ${rsa_count} RSAs — target one explicitly${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Ad group has multiple RSAs"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    ad_id=$(echo "$rsa_list" | jq -r '.[0].ad_id')
    ad_group_ad_id=$(echo "$rsa_list" | jq -r '.[0].ad_group_ad_id')
    echo -e "  ✅ RSA: ${ad_group_ad_id} (ad ${ad_id})"

    # Read the assets already live, then merge. The API replaces the whole
    # list on update, so we must send the full intended set — never only the
    # new assets.
    existing_assets=$(fetch_rsa_assets "$CUSTOMER_ID" "$ad_id")
    draft_assets=$(jq -n \
      --argjson h "$(echo "$action" | jq -c '.asset_headlines // []')" \
      --argjson d "$(echo "$action" | jq -c '.asset_descriptions // []')" \
      --argjson u "$(echo "$action" | jq -c '.asset_final_urls // []')" \
      '{headlines: $h, descriptions: $d, final_urls: $u}')

    replace_mode=$(echo "$action" | jq -r '.asset_replace // false')
    merged_assets=$(asset_merge_lists "$existing_assets" "$draft_assets" "$replace_mode")

    merged_err=$(asset_validate_merged "$merged_assets")
    if [ -n "$merged_err" ]; then
      echo -e "  ${RED}❌ Merged asset list invalid: ${merged_err}${NC}"
      action=$(echo "$action" | jq --arg msg "Merged asset list invalid: $merged_err" '. + {valid: false, error: $msg}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    # Snapshot the pre-change list — this is what undo restores.
    action=$(echo "$action" | jq \
      --arg adid "$ad_id" \
      --arg agadid "$ad_group_ad_id" \
      --argjson merged "$merged_assets" \
      --argjson snapshot "$existing_assets" \
      '. + {
        ad_id: $adid,
        ad_group_ad_id: $agadid,
        merged_headlines: $merged.headlines,
        merged_descriptions: $merged.descriptions,
        merged_final_urls: $merged.final_urls,
        snapshot: $snapshot
      }')

    live_h=$(echo "$existing_assets" | jq '.headlines | length')
    live_d=$(echo "$existing_assets" | jq '.descriptions | length')
    new_h=$(echo "$merged_assets" | jq '.headlines | length')
    new_d=$(echo "$merged_assets" | jq '.descriptions | length')
    echo -e "  ✅ Assets: ${live_h}→${new_h} headline(s), ${live_d}→${new_d} description(s)${replace_mode:+ (replace)}"
  fi

  if [ "$action_type" = "CREATE_ADGROUP_ASSET" ]; then
    if [ -z "$adgroup_name" ]; then
      echo -e "  ${RED}❌ Asset action must name an ad group${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Ad group not named in draft"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    asset_type=$(echo "$action" | jq -r '.asset_type')
    echo -e "  ✅ Asset type: ${asset_type} → ad group \"${adgroup_name}\""
  fi

  # ─── Performance Max asset group actions (v5) ───
  # A Performance Max campaign carries asset groups, not ad groups. The draft
  # names the asset group and the layer resolves it by name inside the
  # campaign — never by a raw id — so a typo cannot hit an unrelated group.
  if [ "$action_type" = "UPDATE_ASSET_GROUP_ASSETS" ]; then
    asset_group_name=$(echo "$action" | jq -r '.asset_group_name // empty')

    if [ -z "$asset_group_name" ]; then
      echo -e "  ${RED}❌ Asset group action must name an asset group${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Asset group not named in draft"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    ag_list=$(lookup_asset_group "$CUSTOMER_ID" "$campaign_name" "$asset_group_name")
    ag_count=$(echo "$ag_list" | jq 'length' 2>/dev/null || echo 0)

    if [ "$ag_count" -eq 0 ]; then
      echo -e "  ${RED}❌ Asset group not found: \"${asset_group_name}\" in \"${campaign_name}\"${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Asset group not found"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    if [ "$ag_count" -gt 1 ]; then
      echo -e "  ${RED}❌ Asset group name \"${asset_group_name}\" is not unique in \"${campaign_name}\"${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Asset group name is not unique"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    asset_group_id=$(echo "$ag_list" | jq -r '.[0].asset_group_id')
    echo -e "  ✅ Asset group: \"${asset_group_name}\" → ID ${asset_group_id}"

    # Read what is live right now — the write is read-modify-write, and the
    # snapshot taken here is what undo restores.
    existing_ag=$(fetch_asset_group_assets "$CUSTOMER_ID" "$asset_group_id")

    # Every asset named for removal must exist live. A removal that names
    # nothing is a typo, not a no-op.
    remove_list=$(echo "$action" | jq -c '.asset_group_remove_assets // []')
    remove_err=$(asset_group_validate_removals "$remove_list" "$existing_ag")
    if [ -n "$remove_err" ]; then
      echo -e "  ${RED}❌ Removal target is not live: ${remove_err}${NC}"
      action=$(echo "$action" | jq --arg msg "Removal target not live: $remove_err" '. + {valid: false, error: $msg}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    draft_lists=$(jq -n \
      --argjson h "$(echo "$action" | jq -c '.asset_group_headlines // []')" \
      --argjson l "$(echo "$action" | jq -c '.asset_group_long_headlines // []')" \
      --argjson d "$(echo "$action" | jq -c '.asset_group_descriptions // []')" \
      '{HEADLINE: $h, LONG_HEADLINE: $l, DESCRIPTION: $d}')

    replace_flag=$(echo "$action" | jq -r '.asset_group_replace // false')
    merged_ag=$(asset_group_merge_lists "$existing_ag" "$draft_lists" "$remove_list" "$replace_flag")

    # What has to be created: merged entries whose text is not live yet.
    additions=$(jq -n --argjson merged "$merged_ag" --argjson existing "$existing_ag" '
      (
        (($merged.HEADLINE // [])
          | map(select((.text as $t | (($existing.HEADLINE // []) | map(.text) | index($t)) == null))
                 | {field_type: "HEADLINE", text: .text}))
        +
        (($merged.LONG_HEADLINE // [])
          | map(select((.text as $t | (($existing.LONG_HEADLINE // []) | map(.text) | index($t)) == null))
                 | {field_type: "LONG_HEADLINE", text: .text}))
        +
        (($merged.DESCRIPTION // [])
          | map(select((.text as $t | (($existing.DESCRIPTION // []) | map(.text) | index($t)) == null))
                 | {field_type: "DESCRIPTION", text: .text}))
      )')

    # What has to be unlinked.
    removals=$(echo "$merged_ag" | jq -c '[.removed[]? | {field_type, text, resource_name}]')

    if [ "$(echo "$additions" | jq 'length')" -eq 0 ] && [ "$(echo "$removals" | jq 'length')" -eq 0 ]; then
      echo -e "  ${YELLOW}⏭️  Every draft asset is already live — nothing to change${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "No asset changes (draft assets already live)"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
      continue
    fi

    slots=$(asset_group_slot_report "$merged_ag")

    action=$(echo "$action" | jq \
      --arg agid "$asset_group_id" \
      --argjson merged "$merged_ag" \
      --argjson existing "$existing_ag" \
      --argjson additions "$additions" \
      --argjson removals "$removals" \
      --argjson slots "$slots" \
      '. + {
        asset_group_id: $agid,
        asset_group_merged: $merged,
        asset_group_snapshot: $existing,
        asset_group_additions: $additions,
        asset_group_removals: $removals,
        asset_group_slots: $slots
      }')

    live_h=$(echo "$existing_ag" | jq '.HEADLINE | length')
    live_lh=$(echo "$existing_ag" | jq '.LONG_HEADLINE | length')
    live_d=$(echo "$existing_ag" | jq '.DESCRIPTION | length')
    new_h=$(echo "$merged_ag" | jq '.HEADLINE | length')
    new_lh=$(echo "$merged_ag" | jq '.LONG_HEADLINE | length')
    new_d=$(echo "$merged_ag" | jq '.DESCRIPTION | length')
    echo -e "  ✅ Assets: HEADLINE ${live_h}→${new_h}, LONG_HEADLINE ${live_lh}→${new_lh}, DESCRIPTION ${live_d}→${new_d}"

    # The published caps do not match what the API enforces (measured on this
    # account), so this is a warning for the operator, not a gate. The real
    # gate is the validate_only request that runs before the write.
    over_slots=$(echo "$slots" | jq -r '[to_entries[] | select(.value.over) | .key] | join(", ")')
    if [ -n "$over_slots" ]; then
      echo -e "  ${YELLOW}⚠️  Over the published cap on: ${over_slots} — the API decides, validate_only is the gate${NC}"
    fi
  fi

  # For ad group pause actions, resolve the ad group ID
  if [ "$action_type" = "PAUSE_ADGROUP" ]; then
    if [ -z "$adgroup_name" ]; then
      # Use keyword field as the ad group name for pause-draft template format
      adgroup_name="$keyword"
    fi
    if [ -n "$campaign_id" ]; then
      adgroup_id=$(lookup_adgroup_id "$CUSTOMER_ID" "$campaign_name" "$adgroup_name")
    else
      # Fallback: look up without campaign
      adgroup_id=$(lookup_adgroup_id_by_name "$CUSTOMER_ID" "$adgroup_name")
    fi
    if [ -z "$adgroup_id" ]; then
      echo -e "  ${RED}❌ Ad group not found for pause: \"${adgroup_name}\"${NC}"
      action=$(echo "$action" | jq '. + {valid: false, error: "Ad group not found for pause"}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
    else
      action=$(echo "$action" | jq --arg agid "$adgroup_id" '. + {adgroup_id: $agid}')
      echo -e "  ✅ Ad group (pause): \"${adgroup_name}\" → ID ${adgroup_id}"
    fi
  fi

  case "$action_type" in
    ADD_NEGATIVE|SET_CAMPAIGN_DAILY_BUDGET|PAUSE_KEYWORD|PAUSE_ADGROUP|UPDATE_RSA_ASSETS|CREATE_ADGROUP_ASSET|UPDATE_ASSET_GROUP_ASSETS)
      ;;
    *)
      echo -e "  ${RED}❌ Unsupported action type: \"${action_type}\"${NC}"
      action=$(echo "$action" | jq --arg msg "Unsupported action type: ${action_type}" '. + {valid: false, error: $msg}')
      VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
      ;;
  esac

  # Mark as valid if no errors added
  action=$(echo "$action" | jq 'if .valid == null then . + {valid: true} else . end')

  RESOLVED_ACTIONS=$(echo "$RESOLVED_ACTIONS" | jq --argjson a "$action" '. + [$a]')
done

VALID_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true)] | length')
echo ""
echo "  Valid actions: ${VALID_COUNT}/${ACTION_COUNT}"

if [ "$VALID_COUNT" -eq 0 ]; then
  echo -e "${RED}No valid actions. Cannot proceed.${NC}"
  exit 1
fi

# Budget policy guardrail (v2 default): stay budget-neutral unless the manifest
# explicitly opts into a bounded net increase.
VALID_BUDGET_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "SET_CAMPAIGN_DAILY_BUDGET")] | length')
if [ "$VALID_BUDGET_COUNT" -gt 0 ]; then
  SUM_CURRENT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "SET_CAMPAIGN_DAILY_BUDGET") | .current_daily_budget_micros] | add // 0')
  SUM_PROPOSED=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "SET_CAMPAIGN_DAILY_BUDGET") | .proposed_daily_budget_micros] | add // 0')
  NET_DELTA=$((SUM_PROPOSED - SUM_CURRENT))
  if [ "$NET_DELTA" -ne 0 ]; then
    if [ "$NET_DELTA" -gt 0 ] && [ "$ALLOW_NET_INCREASE" = "true" ]; then
      NET_PCT=$(_pct_change_int "$SUM_CURRENT" "$SUM_PROPOSED")
      if [ "$NET_PCT" -gt "$MAX_NET_INCREASE_PCT" ]; then
        echo ""
        echo -e "${RED}ERROR: Budget draft exceeds max allowed net increase.${NC}"
        echo -e "${RED}  Sum current:  ${SUM_CURRENT} micros${NC}"
        echo -e "${RED}  Sum proposed: ${SUM_PROPOSED} micros${NC}"
        echo -e "${RED}  Net change:   +${NET_PCT}% (cap ${MAX_NET_INCREASE_PCT}%)${NC}"
        exit 1
      fi
    else
      echo ""
      echo -e "${RED}ERROR: Budget draft is not budget-neutral (v2 default).${NC}"
      echo -e "${RED}  Sum current:  ${SUM_CURRENT} micros${NC}"
      echo -e "${RED}  Sum proposed: ${SUM_PROPOSED} micros${NC}"
      echo -e "${RED}Add meta.budget_policy.allow_net_increase=true only when a bounded net increase is intentional.${NC}"
      exit 1
    fi
  fi
fi

# Asset guardrail: total headline+description count across the draft.
ASSET_ACTION_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and (.type == "UPDATE_RSA_ASSETS" or .type == "CREATE_ADGROUP_ASSET" or .type == "UPDATE_ASSET_GROUP_ASSETS"))] | length')
if [ "$ASSET_ACTION_COUNT" -gt 0 ]; then
  count_err=$(asset_validate_draft_count "$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and (.type == "UPDATE_RSA_ASSETS" or .type == "CREATE_ADGROUP_ASSET" or .type == "UPDATE_ASSET_GROUP_ASSETS"))]')")
  if [ -n "$count_err" ]; then
    echo ""
    echo -e "${RED}ERROR: Asset draft exceeds max_assets_per_draft (${count_err}).${NC}"
    exit 1
  fi
fi

# ═══════════════════════════════════════════════════════════
# Step 3: Display dry run
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} DRY RUN: $(basename "$DRAFT_FILE")${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "Account: ${CUSTOMER_NAME} (CID: ${CUSTOMER_ID})"
echo "Actions: ${VALID_COUNT} valid / ${ACTION_COUNT} total"
echo ""

printf "%-4s %-16s %-35s %-30s %-6s\n" "#" "Action" "Target" "Detail" "Risk"
printf "%-4s %-16s %-35s %-30s %-6s\n" "---" "----------------" "-----------------------------------" "------------------------------" "------"

for i in $(seq 0 $((ACTION_COUNT - 1))); do
  action=$(echo "$RESOLVED_ACTIONS" | jq ".[$i]")
  valid=$(echo "$action" | jq -r '.valid')
  index=$(echo "$action" | jq -r '.index')
  action_type=$(echo "$action" | jq -r '.type')
  keyword=$(echo "$action" | jq -r '.keyword')
  match_type=$(echo "$action" | jq -r '.match_type')
  campaign=$(echo "$action" | jq -r '.campaign')
  adgroup=$(echo "$action" | jq -r '.adgroup // "-"')
  current_budget=$(echo "$action" | jq -r '.current_daily_budget_micros // empty')
  proposed_budget=$(echo "$action" | jq -r '.proposed_daily_budget_micros // empty')
  budget_pct=$(echo "$action" | jq -r '.budget_pct_change // empty')

  display_type=""
  display_target=""
  display_detail=""
  display_risk="Low"

  case "$action_type" in
    ADD_NEGATIVE)
      display_type="ADD NEG"
      display_target="Campaign: ${campaign}"
      display_detail="\"${keyword}\" [${match_type}]"
      ;;
    SET_CAMPAIGN_DAILY_BUDGET)
      display_type="BUDGET"
      display_target="Campaign: ${campaign}"
      display_detail="${current_budget}->${proposed_budget} (${budget_pct}%)"
      display_risk="Medium"
      ;;
    PAUSE_KEYWORD)
      display_type="PAUSE KW"
      display_target="AG: ${adgroup}"
      display_detail="\"${keyword}\" [${match_type}]"
      ;;
    PAUSE_ADGROUP)
      display_type="PAUSE AG"
      display_target="Campaign: ${campaign}"
      display_detail="${adgroup}"
      ;;
    UPDATE_RSA_ASSETS)
      display_type="RSA ASSETS"
      display_target="AG: ${adgroup}"
      merged_h=$(echo "$action" | jq '.merged_headlines | length')
      merged_d=$(echo "$action" | jq '.merged_descriptions | length')
      display_detail="${merged_h}H/${merged_d}D"
      display_risk="Medium"
      ;;
    CREATE_ADGROUP_ASSET)
      display_type="AD ASSET"
      display_target="AG: ${adgroup}"
      display_detail=$(echo "$action" | jq -r '.asset_type')
      ;;
    UPDATE_ASSET_GROUP_ASSETS)
      display_type="PMX ASSETS"
      display_target="AG: $(echo "$action" | jq -r '.asset_group_name')"
      add_n=$(echo "$action" | jq '.asset_group_additions | length')
      rem_n=$(echo "$action" | jq '.asset_group_removals | length')
      display_detail="+${add_n}/-${rem_n}"
      display_risk="Medium"
      ;;
  esac

  if [ "$valid" = "false" ]; then
    display_risk="SKIP"
  fi

  printf "%-4s %-16s %-35s %-30s %-6s\n" "$index" "$display_type" "${display_target:0:35}" "${display_detail:0:30}" "$display_risk"
done

# ─── Dry Run Summary ───
echo ""
echo -e "${BOLD}Summary:${NC}"

# Count by action type
NEG_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "ADD_NEGATIVE")] | length')
BDG_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "SET_CAMPAIGN_DAILY_BUDGET")] | length')
PAUSE_KW_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "PAUSE_KEYWORD")] | length')
PAUSE_AG_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "PAUSE_ADGROUP")] | length')
RSA_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "UPDATE_RSA_ASSETS")] | length')
ASSET_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "CREATE_ADGROUP_ASSET")] | length')
AG_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "UPDATE_ASSET_GROUP_ASSETS")] | length')
SKIP_COUNT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == false)] | length')

[ "$NEG_COUNT" -gt 0 ] && echo -e "  • ${NEG_COUNT} negative keyword addition(s)"
[ "$BDG_COUNT" -gt 0 ] && echo -e "  • ${BDG_COUNT} budget change(s)"
[ "$PAUSE_KW_COUNT" -gt 0 ] && echo -e "  • ${PAUSE_KW_COUNT} keyword pause(s)"
[ "$PAUSE_AG_COUNT" -gt 0 ] && echo -e "  • ${PAUSE_AG_COUNT} ad group pause(s)"
[ "$RSA_COUNT" -gt 0 ] && echo -e "  • ${RSA_COUNT} RSA asset update(s)"
[ "$ASSET_COUNT" -gt 0 ] && echo -e "  • ${ASSET_COUNT} extension asset(s)"
[ "$AG_COUNT" -gt 0 ] && echo -e "  • ${AG_COUNT} Performance Max asset group update(s)"
[ "$SKIP_COUNT" -gt 0 ] && echo -e "  • ${YELLOW}${SKIP_COUNT} skipped (validation errors)${NC}"

if [ "$RSA_COUNT" -gt 0 ] || [ "$AG_COUNT" -gt 0 ]; then
  echo -e "  • Reversibility: ${GREEN}Assets restorable from snapshot${NC} ${DIM}(performance history of removed assets is not recoverable)${NC}"
else
  echo -e "  • Reversibility: ${GREEN}All actions reversible${NC}"
fi

# Learning-period warning for asset changes. Adding assets resets ad
# strength — CTR can dip for a week or two before the new mix settles.
if [ "$RSA_COUNT" -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}⚠️  RSA asset changes affect live ads.${NC}"
  echo -e "${YELLOW}   New assets start a learning period — expect a temporary CTR dip.${NC}"
  echo -e "${YELLOW}   Removed assets lose their performance history and cannot get it back.${NC}"
fi

if [ "$AG_COUNT" -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}⚠️  Performance Max asset changes affect live ads.${NC}"
  echo -e "${YELLOW}   New assets start a learning period — expect a temporary CTR dip.${NC}"
  echo -e "${YELLOW}   Unlinked assets lose their performance history and cannot get it back.${NC}"
  echo -e "${YELLOW}   Restoring them re-creates the text, not the history.${NC}"
fi

if [ "$BDG_COUNT" -gt 0 ]; then
  SUM_CURRENT=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "SET_CAMPAIGN_DAILY_BUDGET") | .current_daily_budget_micros] | add // 0')
  SUM_PROPOSED=$(echo "$RESOLVED_ACTIONS" | jq '[.[] | select(.valid == true and .type == "SET_CAMPAIGN_DAILY_BUDGET") | .proposed_daily_budget_micros] | add // 0')
  NET_DELTA=$((SUM_PROPOSED - SUM_CURRENT))
  echo -e "  • Net budget delta (micros): ${NET_DELTA}"
  if [ "$ALLOW_NET_INCREASE" = "true" ]; then
    echo -e "  • Budget policy: net increase allowed up to ${MAX_NET_INCREASE_PCT}%"
  else
    echo -e "  • Budget policy: budget-neutral only"
  fi
fi

if [ "$VALIDATION_ERRORS" -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}⚠️  ${VALIDATION_ERRORS} action(s) will be skipped due to validation errors.${NC}"
fi

# ─── Server-side validation (no changes) ───
# validateOnly asks the API to run every check it would run on a real write
# — slot limits, duplicate rules, link validity — and change nothing. This is
# the only gate that knows the account's real limits, so it runs before any
# write, and it can also be run on its own with --validate-only.
if $VALIDATE_ONLY; then
  echo ""
  echo -e "${BLUE}Server-side validation (validateOnly — no changes are made)${NC}"

  VALIDATE_FAILED=0
  for i in $(seq 0 $((ACTION_COUNT - 1))); do
    action=$(echo "$RESOLVED_ACTIONS" | jq ".[$i]")
    [ "$(echo "$action" | jq -r '.valid')" = "false" ] && continue

    action_type=$(echo "$action" | jq -r '.type')
    action_index=$(echo "$action" | jq -r '.index')

    case "$action_type" in
      UPDATE_ASSET_GROUP_ASSETS)
        validate_result=$(mutate_asset_group_bulk \
          "$CUSTOMER_ID" \
          "$(echo "$action" | jq -r '.asset_group_id')" \
          "$(echo "$action" | jq -c '.asset_group_additions')" \
          "$(echo "$action" | jq -c '.asset_group_removals')" \
          "true")
        ;;
      UPDATE_RSA_ASSETS)
        validate_result=$(mutate_update_rsa_assets \
          "$CUSTOMER_ID" \
          "$(echo "$action" | jq -r '.ad_id')" \
          "$(echo "$action" | jq -c '.merged_headlines')" \
          "$(echo "$action" | jq -c '.merged_descriptions')" \
          "$(echo "$action" | jq -c '.merged_final_urls')" \
          "true")
        ;;
      *)
        continue
        ;;
    esac

    if [ "$(echo "$validate_result" | jq -r '.success')" != "true" ]; then
      validate_error=$(echo "$validate_result" | jq -r '.error // "validation failed"')
      echo -e "  ${RED}❌ [${action_index}] ${action_type}: ${validate_error}${NC}"
      VALIDATE_FAILED=$((VALIDATE_FAILED + 1))
    else
      echo -e "  ${GREEN}✅ [${action_index}] ${action_type}: accepted by the live API${NC}"
    fi
  done

  echo ""
  if [ "$VALIDATE_FAILED" -gt 0 ]; then
    echo -e "${RED}${VALIDATE_FAILED} action(s) were rejected by the live API. Nothing was changed.${NC}"
    exit 1
  fi
  echo -e "${GREEN}All actions are accepted by the live API. Nothing was changed.${NC}"
  exit 0
fi

echo ""
echo -e "${RED}⚠️  This will make REAL changes to Google Ads account ${CUSTOMER_ID}.${NC}"

if $DRY_RUN_ONLY; then
  echo ""
  echo -e "${BLUE}(Dry run mode — no changes will be made)${NC}"
  echo ""
  echo -e "Next steps:"
  echo -e "  • Remove --dry-run to apply:  ${DIM}gads-apply.sh <draft-file>${NC}"
  echo -e "  • Review the draft:           ${DIM}cat <draft-file>${NC}"
  echo -e "  • Check operator status:      ${DIM}gads-status.sh${NC}"
  exit 0
fi

# ═══════════════════════════════════════════════════════════
# Step 4: Human confirmation
# ═══════════════════════════════════════════════════════════
echo ""
if [ "$BDG_COUNT" -gt 0 ] && [ "$ASSET_ACTION_COUNT" -gt 0 ]; then
  echo -n "Type 'confirm budgets and assets' to proceed, or 'cancel' to abort: "
elif [ "$BDG_COUNT" -gt 0 ]; then
  echo -n "Type 'confirm budgets' to proceed, or 'cancel' to abort: "
elif [ "$ASSET_ACTION_COUNT" -gt 0 ]; then
  echo -n "Type 'confirm assets' to proceed, or 'cancel' to abort: "
else
  echo -n "Type 'confirm' to proceed, or 'cancel' to abort: "
fi
read -r confirmation

if [ "$BDG_COUNT" -gt 0 ] && [ "$ASSET_ACTION_COUNT" -gt 0 ]; then
  if [ "$confirmation" != "confirm budgets and assets" ]; then
    echo -e "${YELLOW}Cancelled. No changes made.${NC}"
    exit 0
  fi
elif [ "$BDG_COUNT" -gt 0 ]; then
  if [ "$confirmation" != "confirm budgets" ]; then
    echo -e "${YELLOW}Cancelled. No changes made.${NC}"
    exit 0
  fi
elif [ "$ASSET_ACTION_COUNT" -gt 0 ]; then
  if [ "$confirmation" != "confirm assets" ]; then
    echo -e "${YELLOW}Cancelled. No changes made.${NC}"
    exit 0
  fi
else
  if [ "$confirmation" != "confirm" ]; then
    echo -e "${YELLOW}Cancelled. No changes made.${NC}"
    exit 0
  fi
fi

echo ""
if [ "$BDG_COUNT" -gt 0 ] && $FORCE; then
  echo -e "${YELLOW}⚠️  --force enabled (budget cooldown override may have been used).${NC}"
  echo ""
fi

echo -e "${GREEN}Confirmed. Executing ${VALID_COUNT} actions...${NC}"

# ═══════════════════════════════════════════════════════════
# Step 5: Execute mutations
# ═══════════════════════════════════════════════════════════
init_apply_session "$DRAFT_FILE" "$CUSTOMER_ID" "$CUSTOMER_NAME" "$VALID_COUNT"

SUCCEEDED=0
FAILED=0

for i in $(seq 0 $((ACTION_COUNT - 1))); do
  action=$(echo "$RESOLVED_ACTIONS" | jq ".[$i]")
  valid=$(echo "$action" | jq -r '.valid')

  if [ "$valid" = "false" ]; then
    log_action_result \
      "$(echo "$action" | jq -r '.index')" \
      "$(echo "$action" | jq -r '.type')" \
      "skipped" \
      "$(echo "$action" | jq -r '.error // "validation failed"')" \
      "⏭️ Skipped" \
      "-"
    continue
  fi

  action_type=$(echo "$action" | jq -r '.type')
  keyword=$(echo "$action" | jq -r '.keyword')
  match_type=$(echo "$action" | jq -r '.match_type')
  campaign_name=$(echo "$action" | jq -r '.campaign')
  campaign_id=$(echo "$action" | jq -r '.campaign_id')
  adgroup_name=$(echo "$action" | jq -r '.adgroup // empty')
  adgroup_id=$(echo "$action" | jq -r '.adgroup_id // empty')
  criterion_id=$(echo "$action" | jq -r '.criterion_id // empty')
  budget_rn=$(echo "$action" | jq -r '.campaign_budget_resource_name // empty')
  current_budget=$(echo "$action" | jq -r '.current_daily_budget_micros // empty')
  proposed_budget=$(echo "$action" | jq -r '.proposed_daily_budget_micros // empty')
  budget_pct=$(echo "$action" | jq -r '.budget_pct_change // empty')
  action_index=$(echo "$action" | jq -r '.index')
  ad_id=$(echo "$action" | jq -r '.ad_id // empty')

  if [ "$action_type" = "SET_CAMPAIGN_DAILY_BUDGET" ]; then
    echo -n "  [${action_index}] ${action_type}: ${campaign_name} (${current_budget}->${proposed_budget}) ... "
  elif [ "$action_type" = "UPDATE_ASSET_GROUP_ASSETS" ]; then
    echo -n "  [${action_index}] ${action_type}: \"$(echo "$action" | jq -r '.asset_group_name')\" ... "
  else
    echo -n "  [${action_index}] ${action_type}: \"${keyword}\" ... "
  fi

  result=""
  resource_name=""
  reversal_id=$(next_reversal_id)

  case "$action_type" in
    ADD_NEGATIVE)
      if [ "$(echo "$action" | jq -r '.scope')" = "AD_GROUP" ]; then
        result=$(mutate_add_negative_adgroup "$CUSTOMER_ID" "$adgroup_id" "$keyword" "$match_type")
      else
        result=$(mutate_add_negative_campaign "$CUSTOMER_ID" "$campaign_id" "$keyword" "$match_type")
      fi
      ;;
    SET_CAMPAIGN_DAILY_BUDGET)
      result=$(mutate_set_campaign_budget_micros "$CUSTOMER_ID" "$budget_rn" "$proposed_budget")
      ;;
    PAUSE_KEYWORD)
      result=$(mutate_pause_keyword "$CUSTOMER_ID" "$adgroup_id" "$criterion_id")
      ;;
    PAUSE_ADGROUP)
      result=$(mutate_pause_adgroup "$CUSTOMER_ID" "$adgroup_id")
      ;;
    UPDATE_RSA_ASSETS)
      # Server-side dry run first: validateOnly checks every limit, pin rule
      # and duplicate-text rule against the real account without changing it.
      merged_h=$(echo "$action" | jq -c '.merged_headlines')
      merged_d=$(echo "$action" | jq -c '.merged_descriptions')
      merged_u=$(echo "$action" | jq -c '.merged_final_urls')
      validate_result=$(mutate_update_rsa_assets "$CUSTOMER_ID" "$ad_id" "$merged_h" "$merged_d" "$merged_u" "true")
      if [ "$(echo "$validate_result" | jq -r '.success')" != "true" ]; then
        echo -e "${RED}❌ server validation failed${NC}"
        result="$validate_result"
      else
        result=$(mutate_update_rsa_assets "$CUSTOMER_ID" "$ad_id" "$merged_h" "$merged_d" "$merged_u" "false")
      fi
      ;;
    CREATE_ADGROUP_ASSET)
      # Extension assets need two calls: create the asset, then link it to
      # the ad group. A failure between them leaves an orphan asset, so the
      # created asset id goes into the reversal record either way.
      asset_type=$(echo "$action" | jq -r '.asset_type')      asset_body=$(echo "$action" | jq -c '
        . as $a
        | ($a.asset_type) as $t
        | {
            name: ("asset-" + ($a.asset_type // "") + "-" + ($a.asset_link_text // $a.asset_text // $a.asset_header // "")),
            sitelinkAsset: (if $t == "SITELINK" then {
              linkText: $a.asset_link_text,
              descriptionLine1: $a.asset_description_line_1,
              descriptionLine2: $a.asset_description_line_2,
              finalUrl: $a.asset_final_url,
              startDate: $a.asset_start_date,
              endDate: $a.asset_end_date
            } else null end),
            calloutAsset: (if $t == "CALLOUT" then {} else null end),
            textAsset: (if $t == "CALLOUT" then {text: $a.asset_text} else null end),
            structuredSnippetAsset: (if $t == "STRUCTURED_SNIPPET" then {
              header: $a.asset_header,
              values: $a.asset_values
            } else null end)
          }
        | with_entries(select(.value != null))')

      create_result=$(mutate_create_asset "$CUSTOMER_ID" "$asset_type" "$asset_body" "false")
      if [ "$(echo "$create_result" | jq -r '.success')" != "true" ]; then
        result="$create_result"
      else
        created_asset_rn=$(echo "$create_result" | jq -r '.resource_name')
        created_asset_id="${created_asset_rn##*/}"
        link_result=$(mutate_link_adgroup_asset "$CUSTOMER_ID" "$adgroup_id" "$created_asset_rn" "$asset_type" "false")
        if [ "$(echo "$link_result" | jq -r '.success')" != "true" ]; then
          # Link failed — surface the orphan asset so it can be cleaned up.
          result=$(echo "$link_result" | jq --arg orphan "$created_asset_rn" \
            '. + {orphan_asset: $orphan, error: (.error + " (orphan asset: " + $orphan + ")")}')
        else
          result=$(echo "$link_result" | jq --arg assetid "$created_asset_id" --arg assetrn "$created_asset_rn" \
            '. + {created_asset_id: $assetid, created_asset_rn: $assetrn}')
        fi
      fi
      ;;
    UPDATE_ASSET_GROUP_ASSETS)
      # One bulk request: every asset is created and linked in the same call,
      # because a temporary resource name does not resolve across calls.
      # Removals ride in the same request so the freed slot counts toward
      # the limit check on the additions.
      ag_id=$(echo "$action" | jq -r '.asset_group_id')
      ag_additions=$(echo "$action" | jq -c '.asset_group_additions')
      ag_removals=$(echo "$action" | jq -c '.asset_group_removals')

      # Server-side dry run first: validateOnly checks the real slot limits
      # and every duplicate rule against the live account without changing it.
      # This is the gate — the local slot report is advisory only.
      ag_validate=$(mutate_asset_group_bulk "$CUSTOMER_ID" "$ag_id" "$ag_additions" "$ag_removals" "true")
      if [ "$(echo "$ag_validate" | jq -r '.success')" != "true" ]; then
        echo -e "${RED}❌ server validation failed${NC}"
        result="$ag_validate"
      else
        result=$(mutate_asset_group_bulk "$CUSTOMER_ID" "$ag_id" "$ag_additions" "$ag_removals" "false")
      fi
      ;;
  esac

  success=$(echo "$result" | jq -r '.success')
  resource_name=$(echo "$result" | jq -r '.resource_name // empty')
  already_exists=$(echo "$result" | jq -r '.already_exists // false')

  if [ "$success" = "true" ]; then
    if [ "$already_exists" = "true" ]; then
      echo -e "${YELLOW}already exists${NC}"
      log_action_result "$action_index" "$action_type" "$campaign_name" "\"$keyword\" [$match_type]" "⏭️ Already exists" "-"
    else
      echo -e "${GREEN}✅${NC}"
      SUCCEEDED=$((SUCCEEDED + 1))

      # Build reversal record
      reversal_action=""
      reversal_resource=""
      case "$action_type" in
        ADD_NEGATIVE)
          if [ "$(echo "$action" | jq -r '.scope')" = "AD_GROUP" ]; then
            reversal_action="REMOVE_NEGATIVE_ADGROUP"
          else
            reversal_action="REMOVE_NEGATIVE_CAMPAIGN"
          fi
          reversal_resource="$resource_name"
          ;;
        SET_CAMPAIGN_DAILY_BUDGET)
          reversal_action="RESTORE_CAMPAIGN_DAILY_BUDGET"
          reversal_resource="$budget_rn"
          ;;
        PAUSE_KEYWORD)
          reversal_action="ENABLE_KEYWORD"
          reversal_resource="$resource_name"
          ;;
        PAUSE_ADGROUP)
          reversal_action="ENABLE_ADGROUP"
          reversal_resource="$resource_name"
          ;;
        UPDATE_RSA_ASSETS)
          # Undo restores the exact asset list captured before the change.
          reversal_action="RESTORE_RSA_ASSETS"
          reversal_resource="$resource_name"
          ;;
        CREATE_ADGROUP_ASSET)
          reversal_action="REMOVE_ADGROUP_ASSET"
          reversal_resource="$resource_name"
          ;;
        UPDATE_ASSET_GROUP_ASSETS)
          # Undo restores the asset group to the pre-change list: it unlinks
          # what this action added and re-creates what it unlinked.
          reversal_action="RESTORE_ASSET_GROUP_ASSETS"
          reversal_resource=$(echo "$action" | jq -r '.asset_group_id')
          ;;
      esac

      # For budgets, store before/after in reversal record; keep keyword/match fields stable for registry tooling.
      if [ "$action_type" = "SET_CAMPAIGN_DAILY_BUDGET" ]; then
        keyword="-"
        match_type="N/A"
      fi

      # Asset actions keep the pre-change list in `snapshot` — that is what
      # undo restores. Other action types leave it null.
      asset_snapshot=$(echo "$action" | jq -c '.snapshot // null')
      if [ "$action_type" = "UPDATE_ASSET_GROUP_ASSETS" ]; then
        asset_snapshot=$(echo "$action" | jq -c '.asset_group_snapshot')
      fi
      created_asset_id=$(echo "$result" | jq -r '.created_asset_id // ""')
      created_asset_rn=$(echo "$result" | jq -r '.created_asset_rn // ""')
      if [ "$action_type" = "UPDATE_RSA_ASSETS" ] || [ "$action_type" = "CREATE_ADGROUP_ASSET" ]; then
        keyword="-"
        match_type="N/A"
      fi
      if [ "$action_type" = "UPDATE_ASSET_GROUP_ASSETS" ]; then
        keyword="-"
        match_type="N/A"
      fi

      # What the asset-group action created and what it unlinked. Undo needs
      # both: it removes the added links and re-creates the removed texts.
      ag_added=$(echo "$action" | jq -c '[.asset_group_additions[]? | {field_type, text}]')
      ag_removed=$(echo "$action" | jq -c '[.asset_group_removals[]? | {field_type, text}]')
      ag_id=$(echo "$action" | jq -r '.asset_group_id // ""')

      reversal_record=$(jq -n \
        --arg id "$reversal_id" \
        --arg action "$action_type" \
        --arg keyword "$keyword" \
        --arg matchType "$match_type" \
        --arg scope "$(echo "$action" | jq -r '.scope')" \
        --arg campaignName "$campaign_name" \
        --arg campaignId "$campaign_id" \
        --arg accountId "$CUSTOMER_ID" \
        --arg appliedAt "$(gads_now_iso)" \
        --arg draftSource "$(basename "$DRAFT_FILE")" \
        --arg reversalAction "$reversal_action" \
        --arg reversalResource "$reversal_resource" \
        --arg resourceName "$resource_name" \
        --arg budgetResourceName "$budget_rn" \
        --arg createdAssetId "$created_asset_id" \
        --arg createdAssetRn "$created_asset_rn" \
        --arg assetGroupId "$ag_id" \
        --argjson beforeMicros "${current_budget:-0}" \
        --argjson afterMicros "${proposed_budget:-0}" \
        --argjson assetSnapshot "$asset_snapshot" \
        --argjson addedAssets "$ag_added" \
        --argjson removedAssets "$ag_removed" \
        '{
          id: $id,
          action: $action,
          keyword: $keyword,
          matchType: $matchType,
          scope: $scope,
          campaignName: $campaignName,
          campaignId: $campaignId,
          accountId: $accountId,
          appliedAt: $appliedAt,
          appliedBy: "operator",
          draftSource: $draftSource,
          reversalAction: $reversalAction,
          reversalResourceName: $reversalResource,
          resourceName: $resourceName,
          budgetResourceName: (if $budgetResourceName == "" then null else $budgetResourceName end),
          beforeMicros: $beforeMicros,
          afterMicros: $afterMicros,
          snapshot: $assetSnapshot,
          createdAssetId: (if $createdAssetId == "" then null else $createdAssetId end),
          createdAssetResourceName: (if $createdAssetRn == "" then null else $createdAssetRn end),
          assetGroupId: (if $assetGroupId == "" then null else $assetGroupId end),
          addedAssets: $addedAssets,
          removedAssets: $removedAssets,
          status: "active",
          undoneAt: null
        }')

      add_reversal_record "$reversal_record"
      if [ "$action_type" = "SET_CAMPAIGN_DAILY_BUDGET" ]; then
        log_action_result "$action_index" "$action_type" "$campaign_name" "${current_budget}->${proposed_budget} (${budget_pct}%)" "✅ Applied" "$reversal_id" "$budget_rn"
      elif [ "$action_type" = "UPDATE_RSA_ASSETS" ]; then
        log_action_result "$action_index" "$action_type" "${campaign_name}/${adgroup_name}" "$(echo "$action" | jq -r '.merged_headlines | length')H/$(echo "$action" | jq -r '.merged_descriptions | length')D" "✅ Applied" "$reversal_id" "$resource_name"
      elif [ "$action_type" = "CREATE_ADGROUP_ASSET" ]; then
        log_action_result "$action_index" "$action_type" "${campaign_name}/${adgroup_name}" "$(echo "$action" | jq -r '.asset_type')" "✅ Applied" "$reversal_id" "$resource_name"
      elif [ "$action_type" = "UPDATE_ASSET_GROUP_ASSETS" ]; then
        log_action_result "$action_index" "$action_type" "${campaign_name}/$(echo "$action" | jq -r '.asset_group_name')" "+$(echo "$ag_added" | jq 'length')/-$(echo "$ag_removed" | jq 'length')" "✅ Applied" "$reversal_id" "$ag_id"
      else
        log_action_result "$action_index" "$action_type" "$campaign_name" "\"$keyword\" [$match_type]" "✅ Applied" "$reversal_id" "$resource_name"
      fi
    fi
  else
    error=$(echo "$result" | jq -r '.error // "Unknown"')
    echo -e "${RED}❌ ${error}${NC}"
    FAILED=$((FAILED + 1))
    if [ "$action_type" = "SET_CAMPAIGN_DAILY_BUDGET" ]; then
      log_action_result "$action_index" "$action_type" "$campaign_name" "${current_budget}->${proposed_budget} (${budget_pct}%)" "❌ Failed: $error" "-"
    else
      log_action_result "$action_index" "$action_type" "$campaign_name" "\"$keyword\" [$match_type]" "❌ Failed: $error" "-"
    fi
  fi

  # Rate limit: small delay between mutations
  sleep 0.5
done

# ═══════════════════════════════════════════════════════════
# Step 6: Verify
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}Step 6: Verifying changes...${NC}"

VERIFY_PASS=0
VERIFY_FAIL=0

for i in $(seq 0 $((ACTION_COUNT - 1))); do
  action=$(echo "$RESOLVED_ACTIONS" | jq ".[$i]")
  valid=$(echo "$action" | jq -r '.valid')
  [ "$valid" = "false" ] && continue

  action_type=$(echo "$action" | jq -r '.type')
  keyword=$(echo "$action" | jq -r '.keyword')
  match_type=$(echo "$action" | jq -r '.match_type')
  campaign_name=$(echo "$action" | jq -r '.campaign')
  adgroup_name=$(echo "$action" | jq -r '.adgroup // empty')
  proposed_budget=$(echo "$action" | jq -r '.proposed_daily_budget_micros // empty')

  verify_result=""

  case "$action_type" in
    ADD_NEGATIVE)
      if [ "$(echo "$action" | jq -r '.scope')" = "AD_GROUP" ]; then
        verify_result=$(verify_negative_adgroup_exists "$CUSTOMER_ID" "$campaign_name" "$adgroup_name" "$keyword" "$match_type")
      else
        verify_result=$(verify_negative_exists "$CUSTOMER_ID" "$campaign_name" "$keyword" "$match_type")
      fi
      ;;
    SET_CAMPAIGN_DAILY_BUDGET)
      verify_result=$(verify_campaign_budget_micros "$CUSTOMER_ID" "$campaign_name" "$proposed_budget")
      ;;
    PAUSE_KEYWORD)
      verify_result=$(verify_keyword_paused "$CUSTOMER_ID" "$campaign_name" "$adgroup_name" "$keyword")
      ;;
    PAUSE_ADGROUP)
      verify_result=$(verify_adgroup_paused "$CUSTOMER_ID" "$campaign_name" "$adgroup_name")
      ;;
    UPDATE_RSA_ASSETS)
      exp_h=$(echo "$action" | jq -c '.merged_headlines')
      exp_d=$(echo "$action" | jq -c '.merged_descriptions')
      verify_result=$(verify_rsa_assets "$CUSTOMER_ID" "$(echo "$action" | jq -r '.ad_id')" "$exp_h" "$exp_d")
      ;;
    CREATE_ADGROUP_ASSET)
      # The created asset id lives in the reversal record (the execute loop
      # is a separate scope).
      created_asset_id=$(jq -r --arg d "$(basename "$DRAFT_FILE")" \
        '[.reversals[]? | select(.draftSource == $d and .status == "active" and .action == "CREATE_ADGROUP_ASSET")] | last | .createdAssetId // empty' \
        "$REVERSAL_REGISTRY_FILE" 2>/dev/null)
      if [ -z "$created_asset_id" ]; then
        verify_result='{"verified": false, "detail": "created asset id not recorded — cannot verify link"}'
      else
        verify_result=$(verify_adgroup_asset_exists "$CUSTOMER_ID" "$adgroup_name" "$created_asset_id")
      fi
      ;;
    UPDATE_ASSET_GROUP_ASSETS)
      ag_expected=$(echo "$action" | jq -c '.asset_group_merged | {HEADLINE, LONG_HEADLINE, DESCRIPTION}')
      ag_removed_texts=$(echo "$action" | jq -c '[.asset_group_removals[]?.text]')
      verify_result=$(verify_asset_group_assets \
        "$CUSTOMER_ID" \
        "$(echo "$action" | jq -r '.asset_group_id')" \
        "$ag_expected" \
        "$ag_removed_texts")
      ;;
  esac

  verified=$(echo "$verify_result" | jq -r '.verified')
  detail=$(echo "$verify_result" | jq -r '.detail')

  if [ "$verified" = "true" ]; then
    echo -e "  ${GREEN}✅ ${detail}${NC}"
    VERIFY_PASS=$((VERIFY_PASS + 1))
  else
    echo -e "  ${YELLOW}⚠️  ${detail}${NC}"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi
done

# ═══════════════════════════════════════════════════════════
# Step 7: Finalize audit trail
# ═══════════════════════════════════════════════════════════
finalize_apply_session "$SUCCEEDED" "$FAILED"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Apply Session Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Results:${NC}"
echo "  ├── Executed:  ${SUCCEEDED} succeeded, ${FAILED} failed"
echo "  ├── Verified:  ${VERIFY_PASS} confirmed, ${VERIFY_FAIL} unconfirmed"
echo "  └── Skipped:   $((ACTION_COUNT - VALID_COUNT)) (validation errors)"
echo ""
echo -e "  ${BOLD}Audit Trail:${NC}"
echo "  ├── Session:   ${_SESSION_FILE}"
echo "  ├── Registry:  ${REVERSAL_REGISTRY_FILE}"
echo "  └── Master:    workspace/ads/audit-trail/_log.md"
echo ""

# Show reversal IDs for this session
FIRST_REV=$(jq -r --arg d "$(basename "$DRAFT_FILE")" '[.reversals[]? | select(.status == "active" and .draftSource == $d) | .id] | first // empty' "$REVERSAL_REGISTRY_FILE" 2>/dev/null)
if [ -n "$FIRST_REV" ]; then
  echo -e "  ${BOLD}Undo:${NC}"
  echo "  ├── Single:    gads-undo.sh <rev-ID>"
  echo "  ├── All:       gads-undo.sh --draft $(basename "$DRAFT_FILE")"
  echo "  └── List:      gads-undo.sh --list"
  echo ""
fi

if [ "$SUCCEEDED" -gt 0 ] && [ "$FAILED" -eq 0 ] && [ "$VERIFY_FAIL" -eq 0 ]; then
  echo -e "${GREEN}✅ All actions applied and verified successfully.${NC}"
  echo ""
  echo -e "  ${DIM}What to watch for in the next 7 days:${NC}"
  echo -e "  ${DIM}  • Check search term reports for blocked queries${NC}"
  echo -e "  ${DIM}  • Monitor that waste queries stop appearing${NC}"
  echo -e "  ${DIM}  • Run /google-ads daily for a quick health check${NC}"
elif [ "$FAILED" -gt 0 ]; then
  echo -e "${YELLOW}⚠️  Some actions failed. Check the session log for details.${NC}"
  echo "Re-run with the same draft to retry failed actions."
elif [ "$VERIFY_FAIL" -gt 0 ]; then
  echo -e "${YELLOW}⚠️  Some verifications didn't confirm. This may be propagation delay.${NC}"
  echo "Re-check in 5 minutes. Changes usually propagate within 60 seconds."
fi
