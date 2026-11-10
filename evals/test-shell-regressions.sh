#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$ROOT/evals/fixtures/retrieval-regressions"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat > "$TMP_DIR/mcporter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

FIXTURES_DIR="${RETRIEVAL_FIXTURES_DIR:?}"
TEST_CASE="${TEST_CASE:?}"

if [[ "${1:-}" != "call" ]]; then
  echo "expected 'call'" >&2
  exit 1
fi
shift

query="${1:-}"

fixture_path() {
  printf '%s/%s/%s\n' "$FIXTURES_DIR" "$TEST_CASE" "$1"
}

emit() {
  cat "$(fixture_path "$1")"
}

is_account_wide_search_term_view() {
  [[ "$query" == *'resource:"search_term_view"'* ]] &&
  [[ "$query" != *"campaign.advertising_channel_type = 'SEARCH'"* ]] &&
  [[ "$query" != *"campaign.resource_name ="* ]]
}

is_search_only_search_term_view() {
  [[ "$query" == *'resource:"search_term_view"'* ]] &&
  [[ "$query" == *"campaign.advertising_channel_type = 'SEARCH'"* ]]
}

is_campaign_report() {
  [[ "$query" == *'resource:"campaign"'* ]]
}

is_pmax_view() {
  [[ "$query" == *'resource:"campaign_search_term_view"'* ]]
}

is_pmax_insight() {
  [[ "$query" == *'resource:"campaign_search_term_insight"'* ]]
}

case "$TEST_CASE" in
  retrieval_low_spend_then_between_success)
    if is_account_wide_search_term_view && [[ "$query" == *"segments.date DURING LAST_30_DAYS"* ]]; then
      emit step1_last30.json
    elif is_search_only_search_term_view && [[ "$query" == *"segments.date DURING LAST_30_DAYS"* ]]; then
      emit empty.json
    elif is_campaign_report && [[ "$query" == *"segments.date DURING LAST_30_DAYS"* ]]; then
      emit empty.json
    elif is_account_wide_search_term_view && [[ "$query" == *"segments.date DURING LAST_14_DAYS"* ]]; then
      emit empty.json
    elif is_search_only_search_term_view && [[ "$query" == *"segments.date DURING LAST_14_DAYS"* ]]; then
      emit empty.json
    elif is_campaign_report && [[ "$query" == *"segments.date DURING LAST_14_DAYS"* ]]; then
      emit empty.json
    elif is_account_wide_search_term_view && [[ "$query" == *"segments.date BETWEEN"* ]]; then
      emit step1_between.json
    else
      emit empty.json
    fi
    ;;
  retrieval_state_reset)
    if is_account_wide_search_term_view && [[ "$query" == *"segments.date DURING LAST_30_DAYS"* ]]; then
      emit empty.json
    elif is_search_only_search_term_view && [[ "$query" == *"segments.date DURING LAST_30_DAYS"* ]]; then
      emit empty.json
    elif is_campaign_report && [[ "$query" == *"segments.date DURING LAST_30_DAYS"* ]]; then
      emit campaigns_last30.json
    elif is_pmax_view && [[ "$query" == *"customers/1234567890/campaigns/777"* ]]; then
      emit empty.json
    elif is_pmax_insight && [[ "$query" == *"campaign_search_term_insight.campaign_id = 777"* ]]; then
      emit empty.json
    elif is_account_wide_search_term_view && [[ "$query" == *"segments.date DURING LAST_14_DAYS"* ]]; then
      emit empty.json
    elif is_search_only_search_term_view && [[ "$query" == *"segments.date DURING LAST_14_DAYS"* ]]; then
      emit empty.json
    elif is_campaign_report && [[ "$query" == *"segments.date DURING LAST_14_DAYS"* ]]; then
      emit empty.json
    elif is_account_wide_search_term_view && [[ "$query" == *"segments.date BETWEEN"* ]]; then
      emit step1_between.json
    else
      emit empty.json
    fi
    ;;
  negative_non_negative_shared_sets)
    case "$query" in
      *'resource:"campaign_criterion"'*) emit empty.json ;;
      *'resource:"ad_group_criterion"'*) emit empty.json ;;
      *'resource:"shared_set"'*'fields:["shared_set.id","shared_set.name"]'*) emit shared_set_min.json ;;
      *'resource:"shared_set"'*'fields:["shared_set.resource_name","shared_set.name","shared_set.type"]'*) emit shared_set_typed.json ;;
      *) emit empty.json ;;
    esac
    ;;
  negative_verified_filtering)
    case "$query" in
      *'resource:"campaign_criterion"'*) emit empty.json ;;
      *'resource:"ad_group_criterion"'*) emit empty.json ;;
      *'resource:"shared_set"'*'fields:["shared_set.id","shared_set.name"]'*) emit shared_set_min.json ;;
      *'resource:"shared_set"'*'fields:["shared_set.resource_name","shared_set.name","shared_set.type"]'*) emit shared_set_typed.json ;;
      *'resource:"campaign_shared_set"'*"campaign_shared_set.shared_set = 'customers/1234567890/sharedSets/neg-1'"*) emit campaign_shared_neg.json ;;
      *'resource:"shared_criterion"'*"shared_criterion.shared_set = 'customers/1234567890/sharedSets/neg-1'"*"shared_criterion.type = 'KEYWORD'"*) emit shared_criterion_neg.json ;;
      *'resource:"shared_criterion"'*"shared_criterion.shared_set = 'customers/1234567890/sharedSets/neg-1'"*) emit shared_criterion_neg.json ;;
      *) emit empty.json ;;
    esac
    ;;
  *)
    echo "unknown test case: $TEST_CASE" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$TMP_DIR/mcporter"

assert_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq -- "$expected" "$file"; then
    echo "Missing expected text: $expected" >&2
    echo "--- output ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

run_with_stub() {
  local test_case="$1"
  shift
  PATH="$TMP_DIR:$PATH" RETRIEVAL_FIXTURES_DIR="$FIXTURES_DIR" TEST_CASE="$test_case" "$@"
}

bash -n "$ROOT/scripts/search-terms-retrieval.sh"
bash -n "$ROOT/scripts/negative-inventory.sh"
bash -n "$ROOT/scripts/apply-layer/lib/asset-rules.sh"
bash -n "$ROOT/scripts/apply-layer/lib/parse-draft.sh"
bash -n "$ROOT/scripts/apply-layer/lib/api-mutate.sh"
bash -n "$ROOT/scripts/apply-layer/lib/api-verify.sh"
bash -n "$ROOT/scripts/apply-layer/gads-apply.sh"
bash -n "$ROOT/scripts/apply-layer/gads-undo.sh"
bash -n "$ROOT/scripts/apply-layer/gads-review.sh"

OUT1="$TMP_DIR/retrieval-low-spend.out"
run_with_stub retrieval_low_spend_then_between_success "$ROOT/scripts/search-terms-retrieval.sh" 1234567890 > "$OUT1"
assert_contains "$OUT1" 'rows found, but spend is below the $5.00 threshold'
assert_contains "$OUT1" 'Date range: segments.date BETWEEN'
assert_contains "$OUT1" 'Retrieval mode: classic'

OUT2="$TMP_DIR/retrieval-state-reset.out"
run_with_stub retrieval_state_reset "$ROOT/scripts/search-terms-retrieval.sh" 1234567890 > "$OUT2"
assert_contains "$OUT2" 'Retrieval mode: classic'
assert_contains "$OUT2" 'Campaigns probed: 0 total, 0 Search, 0 PMax, 0 other'
assert_contains "$OUT2" 'PMax campaigns without rows: none'

OUT3="$TMP_DIR/negative-non-negative-shared-sets.out"
run_with_stub negative_non_negative_shared_sets "$ROOT/scripts/negative-inventory.sh" 1234567890 > "$OUT3"
assert_contains "$OUT3" 'Verified negative keyword shared sets: 0'
assert_contains "$OUT3" 'Shared negative lists: 0'
assert_contains "$OUT3" 'Shared negative-list attachments: 0'
assert_contains "$OUT3" 'Verification result: No negatives found anywhere'

OUT4="$TMP_DIR/negative-verified-filtering.out"
run_with_stub negative_verified_filtering "$ROOT/scripts/negative-inventory.sh" 1234567890 > "$OUT4"
assert_contains "$OUT4" 'Verified negative keyword shared sets: 1'
assert_contains "$OUT4" 'Shared negative lists: 1'
assert_contains "$OUT4" 'Shared negative-list attachments: 1'
assert_contains "$OUT4" 'Shared negative-list keyword members: 1'
assert_contains "$OUT4" 'Verification result: Negatives are active in the account'

# ─── Asset rules (v3) ──────────────────────────────────────────
# The asset library is pure logic: no API calls, no network. Guardrails are
# checked here so a malformed draft is rejected before it can reach an account.

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "Assertion failed: ${label}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
}

asset_rules() {
  # $1 = function name, $2 = JSON argument (passed via env to survive quoting).
  local fn="$1"
  local arg="$2"
  ARG_JSON="$arg" bash -c "cd '$ROOT' && source scripts/apply-layer/lib/asset-rules.sh && $fn \"\$ARG_JSON\""
}

asset_merge() {
  # $1 = existing json, $2 = draft json, $3 = replace(true|false)
  EXISTING_JSON="$1" DRAFT_JSON="$2" REPLACE_FLAG="$3" bash -c \
    "cd '$ROOT' && source scripts/apply-layer/lib/asset-rules.sh && asset_merge_lists \"\$EXISTING_JSON\" \"\$DRAFT_JSON\" \"\$REPLACE_FLAG\""
}

# A valid RSA asset action produces no error.
assert_eq "asset valid rsa passes" "" "$(asset_rules asset_validate_action '{"type":"UPDATE_RSA_ASSETS","adgroup":"AG","guardrails":{},"asset_final_urls":["https://x.com"],"asset_headlines":[{"text":"Fine headline"}],"asset_descriptions":[{"text":"D"}],"asset_replace":false}')"

# Guardrails reject malformed drafts with a specific reason.
assert_eq "headline over 30 chars blocked" "headline_too_long" "$(asset_rules asset_validate_action '{"type":"UPDATE_RSA_ASSETS","adgroup":"AG","guardrails":{},"asset_final_urls":["https://x.com"],"asset_headlines":[{"text":"This headline is definitely longer than thirty characters"}],"asset_descriptions":[{"text":"D"}],"asset_replace":false}')"
assert_eq "output-only pin field blocked" "headline_pin_invalid" "$(asset_rules asset_validate_action '{"type":"UPDATE_RSA_ASSETS","adgroup":"AG","guardrails":{},"asset_final_urls":["https://x.com"],"asset_headlines":[{"text":"H","pinned_field":"TEXT_DISCLAIMER"}],"asset_descriptions":[{"text":"D"}],"asset_replace":false}')"
assert_eq "duplicate headline blocked" "headline_duplicate" "$(asset_rules asset_validate_action '{"type":"UPDATE_RSA_ASSETS","adgroup":"AG","guardrails":{},"asset_final_urls":["https://x.com"],"asset_headlines":[{"text":"Same"},{"text":"Same"}],"asset_descriptions":[{"text":"D"}],"asset_replace":false}')"
assert_eq "replace without learning ack blocked" "learning_period_not_acknowledged" "$(asset_rules asset_validate_action '{"type":"UPDATE_RSA_ASSETS","adgroup":"AG","guardrails":{},"asset_final_urls":["https://x.com"],"asset_headlines":[{"text":"H"}],"asset_descriptions":[{"text":"D"}],"asset_replace":true}')"
assert_eq "unnamed ad group blocked" "adgroup_not_explicit" "$(asset_rules asset_validate_action '{"type":"UPDATE_RSA_ASSETS","adgroup":"","guardrails":{},"asset_final_urls":["https://x.com"],"asset_headlines":[{"text":"H"}],"asset_descriptions":[{"text":"D"}],"asset_replace":false}')"
assert_eq "unknown asset type blocked" "asset_type_invalid" "$(asset_rules asset_validate_action '{"type":"CREATE_ADGROUP_ASSET","adgroup":"AG","guardrails":{},"asset_type":"MYSTERY"}')"

# Merged list must satisfy the API's own list rules.
assert_eq "merged too few headlines blocked" "merged_headlines_too_few" "$(asset_rules asset_validate_merged '{"headlines":[{"text":"A"}],"descriptions":[{"text":"D"},{"text":"E"}]}')"
assert_eq "merged unfillable pin positions blocked" "merged_pin_positions_unfillable" "$(asset_rules asset_validate_merged '{"headlines":[{"text":"A","pinned_field":"HEADLINE_1"},{"text":"B","pinned_field":"HEADLINE_1"},{"text":"C","pinned_field":"HEADLINE_1"}],"descriptions":[{"text":"D"},{"text":"E"}]}')"

# Merge keeps live assets and adds new ones (read-modify-write contract).
MERGED_OUT=$(asset_merge '{"headlines":[{"text":"Old H1","pinned_field":"HEADLINE_1"},{"text":"Old H2","pinned_field":""}],"descriptions":[{"text":"Old D1","pinned_field":""}],"final_urls":["https://old.x"]}' '{"headlines":[{"text":"New H1","pinned_field":""}],"descriptions":[{"text":"New D1","pinned_field":""}],"final_urls":["https://new.x"]}' false)
assert_eq "merge keeps live assets" "3" "$(echo "$MERGED_OUT" | jq '.headlines | length')"
assert_eq "merge adds new assets" "2" "$(echo "$MERGED_OUT" | jq '.descriptions | length')"

# Replace mode drops live assets.
REPLACED_OUT=$(asset_merge '{"headlines":[{"text":"Old H1","pinned_field":""}],"descriptions":[{"text":"Old D1","pinned_field":""}],"final_urls":[]}' '{"headlines":[{"text":"New H1","pinned_field":""}],"descriptions":[{"text":"New D1","pinned_field":""}],"final_urls":[]}' true)
assert_eq "replace drops live headlines" "1" "$(echo "$REPLACED_OUT" | jq '.headlines | length')"

# ─── Asset draft parsing ───────────────────────────────────────
# The manifest parser must accept a valid asset draft and reject a malformed
# one before any API call happens.
PARSED_ASSET=$(bash -c "cd '$ROOT' && source scripts/apply-layer/lib/parse-draft.sh && parse_draft '$ROOT/evals/fixtures/draft-asset-manifest.md'")
assert_eq "asset draft parses" "2" "$(echo "$PARSED_ASSET" | jq '.action_count')"
assert_eq "asset draft action type" "UPDATE_RSA_ASSETS" "$(echo "$PARSED_ASSET" | jq -r '.actions[0].type')"
assert_eq "asset draft pin preserved" "HEADLINE_1" "$(echo "$PARSED_ASSET" | jq -r '.actions[0].asset_headlines[0].pinned_field')"

# A malformed asset draft fails closed at parse time.
cat > "$TMP_DIR/bad-asset-draft.md" <<'BADEOF'
# Draft: Bad Asset — 2026-11-10
Status: proposed
Account: Test Equipment Co. (1234567890)

## Apply Manifest

~~~json
{
  "draft_version": "0.3",
  "customer_id": "1234567890",
  "actions": [
    {
      "id": "r1",
      "type": "UPDATE_RSA_ASSETS",
      "risk": "medium",
      "reason": "headline too long",
      "targets": {
        "campaign_name": "C",
        "adgroup_name": "AG",
        "final_urls": ["https://example.com"],
        "headlines": [{ "text": "This headline is definitely longer than thirty characters" }],
        "descriptions": [{ "text": "D" }]
      }
    }
  ]
}
~~~
BADEOF

if bash -c "cd '$ROOT' && source scripts/apply-layer/lib/parse-draft.sh && parse_draft '$TMP_DIR/bad-asset-draft.md'" >/dev/null 2>&1; then
  echo "Malformed asset draft was accepted — pre-flight validation is not fail-closed" >&2
  exit 1
fi

# An unknown action type must still be rejected (whitelist stays fail-closed).
cat > "$TMP_DIR/unknown-action-draft.md" <<'UNKNOWNEOF'
# Draft: Unknown Action — 2026-11-10
Status: proposed
Account: Test Equipment Co. (1234567890)

## Apply Manifest

~~~json
{
  "draft_version": "0.3",
  "customer_id": "1234567890",
  "actions": [
    {
      "id": "x1",
      "type": "DELETE_EVERYTHING",
      "risk": "high",
      "reason": "not a real action type",
      "targets": { "campaign_name": "C" }
    }
  ]
}
~~~
UNKNOWNEOF

if bash -c "cd '$ROOT' && source scripts/apply-layer/lib/parse-draft.sh && parse_draft '$TMP_DIR/unknown-action-draft.md'" >/dev/null 2>&1; then
  echo "Unknown action type was accepted — manifest whitelist is not fail-closed" >&2
  exit 1
fi

# ─── Offline preview of the asset apply flow ─────────────────
# Runs the real gads-apply.sh against a stubbed API. It proves the whole
# path works — parse → resolve → merge → execute → verify → audit — without
# a live account.
PREVIEW_OUT="$TMP_DIR/preview.out"
bash "$ROOT/scripts/apply-layer/preview-asset-apply.sh" "$ROOT/evals/fixtures/draft-asset-manifest.md" > "$PREVIEW_OUT" 2>&1

assert_contains "$PREVIEW_OUT" 'RSA live: 4 headline(s), 2 description(s)'
assert_contains "$PREVIEW_OUT" 'Executed:  2 succeeded, 0 failed'
assert_contains "$PREVIEW_OUT" 'Verified:  2 confirmed, 0 unconfirmed'
# The merged list must keep the assets that were already live.
assert_contains "$PREVIEW_OUT" 'Existing Headline One'
assert_contains "$PREVIEW_OUT" 'Certified Crane Operators'
# The reversal snapshot must capture the pre-change list.
assert_contains "$PREVIEW_OUT" 'RESTORE_RSA_ASSETS'
assert_contains "$PREVIEW_OUT" '"reversalAction": "REMOVE_ADGROUP_ASSET"'

# The preview must not touch the real workspace.
if [ -f "$ROOT/workspace/ads/audit-trail/reversal-registry.json" ]; then
  if grep -q '"RESTORE_RSA_ASSETS"' "$ROOT/workspace/ads/audit-trail/reversal-registry.json" 2>/dev/null; then
    echo "Preview leaked a reversal record into the real workspace" >&2
    exit 1
  fi
fi

# ─── Offline undo preview ─────────────────────────────────────
# Undo must restore the exact asset list captured in the snapshot.
UNDO_OUT="$TMP_DIR/undo.out"
bash "$ROOT/scripts/apply-layer/preview-asset-undo.sh" > "$UNDO_OUT" 2>&1

assert_contains "$UNDO_OUT" 'Existing Headline One'
assert_contains "$UNDO_OUT" '"pinnedField": "HEADLINE_1"'
assert_contains "$UNDO_OUT" '"status": "undone"'

echo "Shell regression checks passed."
