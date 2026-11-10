#!/usr/bin/env bash
# asset-rules.sh — Pure validation and merge rules for ad asset actions.
#
# Usage:
#   source lib/asset-rules.sh
#   err=$(asset_validate_action "$action_json"); [ -z "$err" ] && echo "valid"
#
# No network access here on purpose: these rules decide whether a draft is
# well-formed BEFORE anything is sent to Google Ads. The API is still the
# authority (it owns ad strength, policy review, and account limits), but
# catching shape errors locally avoids a pointless round trip and keeps the
# failure message actionable.
#
# Asset action types:
#   UPDATE_RSA_ASSETS     — headline/description text on a responsive search ad
#   CREATE_ADGROUP_ASSET  — extension asset (sitelink / callout / snippet)

set -euo pipefail

# Google Ads RSA limits (verified against the v20 API reference).
ASSET_HEADLINE_MIN=3
ASSET_HEADLINE_MAX=15
ASSET_HEADLINE_CHARS=30
ASSET_DESCRIPTION_MIN=2
ASSET_DESCRIPTION_MAX=4
ASSET_DESCRIPTION_CHARS=90

# Pin positions the API accepts on input. Everything else in
# ServedAssetFieldType is output-only and is rejected with
# AssetLinkError.INVALID_PINNED_FIELD.
ASSET_HEADLINE_PINS='["HEADLINE_1","HEADLINE_2","HEADLINE_3"]'
ASSET_DESCRIPTION_PINS='["DESCRIPTION_1","DESCRIPTION_2"]'

# ─────────────────────────────────────────────────────────────
# Validate one action. Prints an error reason on failure, nothing on success.
# ─────────────────────────────────────────────────────────────
# Operates on the PARSED action shape (asset_headlines / asset_descriptions /
# asset_final_urls / asset_type / ...), not the raw manifest — that is the
# shape both parse-draft.sh and gads-apply.sh work with.
asset_validate_action() {
  local action="$1"

  echo "$action" | jq -r '
    def hchars: 30; def dchars: 90;
    def hmin: 3; def hmax: 15;
    def dmin: 2; def dmax: 4;
    def hpins: ["HEADLINE_1","HEADLINE_2","HEADLINE_3"];
    def dpins: ["DESCRIPTION_1","DESCRIPTION_2"];

    . as $a
    | ($a.type // "") as $t
    | ($a.guardrails // {}) as $gr
    | (
      if $t == "UPDATE_RSA_ASSETS" then
        (
          # ── final URLs ──
          if (($a.asset_final_urls // []) | type) != "array" then "final_urls_not_array"
          elif (($a.asset_final_urls // []) | length) < 1 then "final_urls_missing"
          elif ([$a.asset_final_urls[] | select((type == "string" and test("^https?://")) | not)] | length) > 0 then "final_urls_invalid"
          # ── ad group must be named explicitly (blast-radius guard) ──
          elif ($gr.require_explicit_ad_group // true) and (($a.adgroup // "") | length) == 0 then "adgroup_not_explicit"
          # ── headline / description lists ──
          elif (($a.asset_headlines // []) | type) != "array" then "headlines_not_array"
          elif (($a.asset_descriptions // []) | type) != "array" then "descriptions_not_array"
          elif (($a.asset_headlines // []) | length) < 1 then "headlines_missing"
          elif (($a.asset_descriptions // []) | length) < 1 then "descriptions_missing"
          elif (($a.asset_headlines // []) | length) > hmax then "too_many_headlines"
          elif (($a.asset_descriptions // []) | length) > dmax then "too_many_descriptions"
          elif ([$a.asset_headlines[]? | select(((.text // "") | length) == 0)] | length) > 0 then "headline_empty"
          elif ([$a.asset_descriptions[]? | select(((.text // "") | length) == 0)] | length) > 0 then "description_empty"
          elif ([$a.asset_headlines[]? | select(((.text // "") | length) > hchars)] | length) > 0 then "headline_too_long"
          elif ([$a.asset_descriptions[]? | select(((.text // "") | length) > dchars)] | length) > 0 then "description_too_long"
          # ── pins ──
          elif ([$a.asset_headlines[]? | select((((.pinned_field // null) as $p | $p != null and (hpins | index($p)) == null)))] | length) > 0 then "headline_pin_invalid"
          elif ([$a.asset_descriptions[]? | select((((.pinned_field // null) as $p | $p != null and (dpins | index($p)) == null)))] | length) > 0 then "description_pin_invalid"
          # ── duplicate text inside one list (API: AssetError.DUPLICATE_ASSET) ──
          elif (($a.asset_headlines // []) | map(.text) | unique | length) != (($a.asset_headlines // []) | length) then "headline_duplicate"
          elif (($a.asset_descriptions // []) | map(.text) | unique | length) != (($a.asset_descriptions // []) | length) then "description_duplicate"
          # ── replacing live assets resets ad strength → must be acknowledged ──
          elif (($a.asset_replace // false) == true) and (($gr.acknowledge_learning_period // false) != true) then "learning_period_not_acknowledged"
          else "" end
        )
      elif $t == "CREATE_ADGROUP_ASSET" then
        (
          (($a.asset_type // "") as $at
          | if $at == "SITELINK" then
              (
                if (($a.asset_link_text // "") | length) == 0 then "link_text_missing"
                elif (($a.asset_description_line_1 // "") | length) == 0 then "description_line_1_missing"
                elif (($a.asset_final_url // "") | test("^https?://") | not) then "final_url_invalid"
                elif (($a.asset_start_date // "") | length) > 0 and (($a.asset_start_date // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not) then "start_date_invalid"
                elif (($a.asset_end_date // "") | length) > 0 and (($a.asset_end_date // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not) then "end_date_invalid"
                else "" end
              )
            elif $at == "CALLOUT" then
              (if (($a.asset_text // "") | length) == 0 then "asset_text_missing" else "" end)
            elif $at == "STRUCTURED_SNIPPET" then
              (
                if (($a.asset_header // "") | length) == 0 then "header_missing"
                elif (($a.asset_values // []) | type) != "array" then "values_not_array"
                elif (($a.asset_values // []) | length) < 1 then "values_missing"
                else "" end
              )
            else "asset_type_invalid" end)
        )
      else "" end
    )'
}

# ─────────────────────────────────────────────────────────────
# Validate a MERGED list (what will actually be sent to the API).
# ─────────────────────────────────────────────────────────────
# The merge result must satisfy the API's own list rules, not just the
# draft's shape rules: 3-15 headlines, 2-4 descriptions, and every pin
# position must be fillable by either a pinned asset or a distinct
# unpinned one (AssetLinkError.NOT_ENOUGH_AVAILABLE_ASSET_LINKS_FOR_VALID_COMBINATION).
asset_validate_merged() {
  local merged="$1"

  echo "$merged" | jq -r '
    def hmin: 3; def hmax: 15;
    def dmin: 2; def dmax: 4;

    (.headlines // []) as $h
    | (.descriptions // []) as $d
    | (
      if ($h | length) < hmin then "merged_headlines_too_few"
      elif ($h | length) > hmax then "merged_headlines_too_many"
      elif ($d | length) < dmin then "merged_descriptions_too_few"
      elif ($d | length) > dmax then "merged_descriptions_too_many"
      elif ($h | map(.text) | unique | length) != ($h | length) then "merged_headline_duplicate"
      elif ($d | map(.text) | unique | length) != ($d | length) then "merged_description_duplicate"
      # pin fillability: positions not explicitly pinned need distinct unpinned assets
      elif ([$h[] | select((.pinned_field // "") != "") | .pinned_field] | unique | length) as $hp
           | ($h | map(select((.pinned_field // "") == "")) | length) as $hu
           | (3 - $hp) > $hu then "merged_pin_positions_unfillable"
      elif ([$d[] | select((.pinned_field // "") != "") | .pinned_field] | unique | length) as $dp
           | ($d | map(select((.pinned_field // "") == "")) | length) as $du
           | (2 - $dp) > $du then "merged_pin_positions_unfillable"
      else "" end
    )'
}

# ─────────────────────────────────────────────────────────────
# Merge draft assets with the ones already live.
# ─────────────────────────────────────────────────────────────
# replace=false → keep everything live, add the new ones (draft wins on text
#                 collision so a pinned headline can override an unpinned one)
# replace=true  → the draft list IS the final list
#
# Prints the merged {headlines, descriptions, final_urls} object.
asset_merge_lists() {
  local existing_json="$1"
  local draft_json="$2"
  local replace="$3"

  jq -n \
    --argjson existing "$existing_json" \
    --argjson draft "$draft_json" \
    --argjson replace "$replace" \
    '
    def merge_one($live; $new; $isReplace):
      if $isReplace then $new
      else
        # keep live order, then append new ones that are not already live.
        # On text collision the draft wins (it may carry a pin).
        ($live | map(
          . as $l
          | (($new | map(select(.text == $l.text)) | first) // $l)
        ))
        + ($new | map(select(
            (.text as $t | ($live | map(.text) | index($t)) == null)
          )))
      end;

    {
      headlines: (merge_one(($existing.headlines // []); ($draft.headlines // []); $replace)),
      descriptions: (merge_one(($existing.descriptions // []); ($draft.descriptions // []); $replace)),
      final_urls: (if (($draft.final_urls // []) | length) > 0
                   then $draft.final_urls
                   else ($existing.final_urls // [])
                   end)
    }'
}

# ─────────────────────────────────────────────────────────────
# Draft-level guardrail: total asset count across the whole draft.
# ─────────────────────────────────────────────────────────────
# Prints an error reason when the draft exceeds max_assets_per_draft.
asset_validate_draft_count() {
  local actions_json="$1"

  echo "$actions_json" | jq -r '
    def hmin: 3; def hmax: 15;
    def dmin: 2; def dmax: 4;
    (
      (([.[] | select(.type == "UPDATE_RSA_ASSETS")
            | ((.asset_headlines // []) | length) + ((.asset_descriptions // []) | length)]
           | add // 0)
       + ([.[] | select(.type == "CREATE_ADGROUP_ASSET")] | length)) as $total
      | ([.[] | select(.type == "UPDATE_RSA_ASSETS")
            | (.guardrails.max_assets_per_draft // 10)] | first // 10) as $cap
      | if $total > $cap then "too_many_assets_in_draft" else "" end
    )'
}
