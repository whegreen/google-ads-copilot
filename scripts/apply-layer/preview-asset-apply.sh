#!/usr/bin/env bash
# preview-asset-apply.sh — Offline preview of the v3 asset apply flow.
#
# Usage:
#   scripts/apply-layer/preview-asset-apply.sh <draft-file>
#
# Runs the real gads-apply.sh code path against a STUBBED Google Ads API, so
# the whole flow (parse → resolve → merge → validate → execute → verify →
# audit) can be inspected without touching a live account.
#
# What is stubbed:
#   - OAuth2 token refresh           → returns a fake token
#   - googleAds:searchStream (GAQL)  → returns fixture campaigns / ad groups /
#                                     RSAs and their live assets
#   - ads:mutate                     → records the payload it received
#   - assets:mutate / adGroupAssets:mutate → same
#
# Every request the stub receives is written to $WORKDIR/requests.log so the
# exact payloads can be reviewed — that is the point of this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRAFT_FILE="${1:-}"
if [ -z "$DRAFT_FILE" ]; then
  echo "Usage: preview-asset-apply.sh <draft-file>" >&2
  exit 1
fi
if [[ "$DRAFT_FILE" != /* ]]; then
  DRAFT_FILE="${PROJECT_ROOT}/${DRAFT_FILE}"
fi
if [ ! -f "$DRAFT_FILE" ]; then
  echo "ERROR: Draft file not found: ${DRAFT_FILE}" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"

STUB_BIN="$WORKDIR/bin"
mkdir -p "$STUB_BIN"

# ── Stub curl ────────────────────────────────────────────────
# Records every call, then answers according to the URL.
# Must honour -w "%{http_code}" — the apply layer parses the http code off the
# end of the response, so a stub that ignores it makes every call look failed.
cat > "$STUB_BIN/curl" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail

LOG="${STUB_LOG:-/dev/null}"
METHOD=""
URL=""
BODY=""
WRITE_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --request) METHOD="$2"; shift 2 ;;
    -d) BODY="$2"; shift 2 ;;
    --data) BODY="$2"; shift 2 ;;
    -w) WRITE_OUT="$2"; shift 2 ;;
    # -H takes ONE argument ("Header: value") — shifting 2 would eat the URL.
    -H|--header) shift 2 ;;
    -o|--output) shift 2 ;;
    *) URL="$1"; shift ;;
  esac
done

{
  echo "=== ${METHOD} ${URL}"
  if [ -n "$BODY" ]; then echo "--- body ---"; echo "$BODY"; fi
  echo ""
} >> "$LOG"

emit_json() { printf '%s\n' "$1"; }

respond() {
  # $1 = body, $2 = http code
  # The apply layer reads the http code off the LAST line of the response
  # (`curl -w "\n%{http_code}"` appends it). Emit body, newline, code.
  # Do not try to interpolate the -w format string: bash pattern substitution
  # cannot handle the literal braces in "%{http_code}".
  if [ -n "$WRITE_OUT" ]; then
    printf '%s\n%s\n' "$1" "$2"
  else
    printf '%s\n' "$1"
  fi
}

case "$URL" in
  *oauth2.googleapis.com/token)
    respond '{"access_token":"fake-token","expires_in":3600}' 200
    exit 0
    ;;

  *googleAds:searchStream)
    # GAQL read — answer based on what the query asks for.
    if [[ "$BODY" == *"ad_group_ad.ad.responsive_search_ad.headlines"* ]]; then
      # Live RSA assets. If a previous mutate stored a new list, return that
      # instead — otherwise the verify step would always read stale assets.
      if [ -n "${STUB_STATE_DIR:-}" ] && [ -f "$STUB_STATE_DIR/rsa.json" ]; then
        stored=$(cat "$STUB_STATE_DIR/rsa.json")
        respond "[{\"results\":[{\"adGroupAd\":{\"ad\":{\"id\":\"555\",\"responsiveSearchAd\":${stored},\"finalUrls\":[\"https://example.com/live\"]}}}]}]" 200
        exit 0
      fi
      # Live RSA assets (2 headlines, 1 description, one pinned).
      # finalUrls is a sibling of responsiveSearchAd on the Ad resource.
      respond '[{"results":[{"adGroupAd":{"ad":{"id":"555","responsiveSearchAd":{"headlines":[{"text":"Existing Headline One","pinnedField":"HEADLINE_1"},{"text":"Existing Headline Two"}],"descriptions":[{"text":"Existing description text."}]},"finalUrls":["https://example.com/live"]}}}]}]' 200
    elif [[ "$BODY" == *"ad_group_asset.resource_name"* ]]; then
      # Asset-link verification query.
      if [ -n "${STUB_STATE_DIR:-}" ] && [ -f "$STUB_STATE_DIR/asset_linked" ]; then
        respond '[{"results":[{"adGroupAsset":{"resourceName":"customers/1234567890/adGroupAssets/444~999~SITELINK"}}]}]' 200
      else
        respond '[{"results":[]}]' 200
      fi
    elif [[ "$BODY" == *"ad_group_ad.ad.type = 'RESPONSIVE_SEARCH_AD'"* ]] || [[ "$BODY" == *"ad_group_ad.resource_name"* ]]; then
      # RSA lookup inside the ad group (v25: the AdGroupAd id lives in resource_name).
      respond '[{"results":[{"adGroupAd":{"resourceName":"customers/1234567890/adGroupAds/444~555","ad":{"id":"555","name":"RSA #1","type":"RESPONSIVE_SEARCH_AD"},"status":"ENABLED"}}]}]' 200
    elif [[ "$BODY" == *"FROM asset_group "* ]] || [[ "$BODY" == *"asset_group.id"* ]]; then
      # Performance Max asset group lookup.
      respond '[{"results":[{"assetGroup":{"id":"6677194808","name":"at home daycare feb","status":"ENABLED","finalUrls":["https://kisahtumbuh.org/flexy-member"]}}]}]' 200
    elif [[ "$BODY" == *"FROM ad_group "* ]] || [[ "$BODY" == *"ad_group.id"* ]]; then
      respond '[{"results":[{"adGroup":{"id":"444","name":"Crane Rental"}}]}]' 200
    elif [[ "$BODY" == *"FROM campaign "* ]]; then
      respond '[{"results":[{"campaign":{"id":"333","name":"High Intent - Search"}}]}]' 200
    else
      respond '[{"results":[]}]' 200
    fi
    exit 0
    ;;

  *ads:mutate)
    # Store the applied asset list so the verify step can read it back —
    # that is what proves the update actually landed.
    if [ -n "${STUB_STATE_DIR:-}" ]; then
      echo "$BODY" | jq -c '.operations[0].update.responsiveSearchAd' > "$STUB_STATE_DIR/rsa.json" 2>/dev/null || true
    fi
    respond '{"results":[{"resourceName":"customers/1234567890/ads/555"}]}' 200
    exit 0
    ;;

  *assets:mutate)
    respond '{"results":[{"resourceName":"customers/1234567890/assets/999"}]}' 200
    exit 0
    ;;

  *adGroupAssets:mutate)
    if [ -n "${STUB_STATE_DIR:-}" ]; then
      echo "$BODY" | jq -c '.operations[0].create.asset' > "$STUB_STATE_DIR/asset.json" 2>/dev/null || true
      touch "$STUB_STATE_DIR/asset_linked"
    fi
    respond '{"results":[{"resourceName":"customers/1234567890/adGroupAssets/444~999~SITELINK"}]}' 200
    exit 0
    ;;

  *)
    echo "stub curl: unhandled URL: ${URL}" >&2
    exit 1
    ;;
esac
STUBEOF
chmod +x "$STUB_BIN/curl"

# ── Stub the token cache so no refresh call is needed ────────
# config.sh hardcodes the cache path, so write there (and restore afterwards).
TOKEN_CACHE_PATH="/tmp/gads-copilot-token.json"
TOKEN_CACHE_BACKUP=""
if [ -f "$TOKEN_CACHE_PATH" ]; then
  TOKEN_CACHE_BACKUP="$WORKDIR/token.json.bak"
  cp "$TOKEN_CACHE_PATH" "$TOKEN_CACHE_BACKUP"
fi
jq -n --argjson expires_at "$(( $(date +%s) + 3600 ))" \
  '{access_token:"fake-token", expires_at:$expires_at, refreshed_at:"stub"}' \
  > "$TOKEN_CACHE_PATH"
chmod 600 "$TOKEN_CACHE_PATH"

restore_token_cache() {
  if [ -n "$TOKEN_CACHE_BACKUP" ]; then
    cp "$TOKEN_CACHE_BACKUP" "$TOKEN_CACHE_PATH"
  else
    rm -f "$TOKEN_CACHE_PATH"
  fi
}
trap 'restore_token_cache; rm -rf "$WORKDIR"' EXIT

export STUB_LOG="$WORKDIR/requests.log"
: > "$STUB_LOG"

# The stub keeps the last applied state so the verify step reads back what
# was written, not the initial fixture.
export STUB_STATE_DIR="$WORKDIR/state"
mkdir -p "$STUB_STATE_DIR"

export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-/nonexistent}"
export GOOGLE_ADS_DEVELOPER_TOKEN="fake-developer-token"

# ── Sandbox the workspace ────────────────────────────────────
# audit-write.sh derives PROJECT_ROOT from its own location, so copying the
# apply-layer tree into a sandbox keeps every audit-trail write out of the
# real workspace/ads directory.
SANDBOX="$WORKDIR/sandbox"
mkdir -p "$SANDBOX/scripts" "$SANDBOX/workspace/ads/audit-trail" "$SANDBOX/workspace/ads/drafts"
cp -R "$SCRIPT_DIR" "$SANDBOX/scripts/apply-layer"
cp "$DRAFT_FILE" "$SANDBOX/draft.md"
cp -R "$PROJECT_ROOT/evals" "$SANDBOX/evals" 2>/dev/null || true
cp "$PROJECT_ROOT/drafts/ACTION-MANIFEST.md" "$SANDBOX/ACTION-MANIFEST.md" 2>/dev/null || true

echo "══════════════════════════════════════════════════════════════════"
echo " OFFLINE PREVIEW — stubbed Google Ads API, no live account touched"
echo "══════════════════════════════════════════════════════════════════"
echo ""

# Run the real apply flow, but feed "confirm assets" on stdin so it proceeds
# past the human-confirmation gate. The API itself is stubbed.
printf 'confirm assets\n' | PATH="$STUB_BIN:$PATH" \
  bash "$SANDBOX/scripts/apply-layer/gads-apply.sh" "$SANDBOX/draft.md" 2>&1 | sed 's/^/  /'

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " API REQUESTS THE PREVIEW WOULD SEND"
echo "══════════════════════════════════════════════════════════════════"
cat "$STUB_LOG"

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " REVERSAL RECORD THE PREVIEW WOULD WRITE"
echo "══════════════════════════════════════════════════════════════════"
if [ -f "$SANDBOX/workspace/ads/audit-trail/reversal-registry.json" ]; then
  jq '.reversals[] | {id, action, reversalAction, reversalResourceName, snapshot, createdAssetId}' \
    "$SANDBOX/workspace/ads/audit-trail/reversal-registry.json"
else
  echo "(no reversal record written)"
fi
