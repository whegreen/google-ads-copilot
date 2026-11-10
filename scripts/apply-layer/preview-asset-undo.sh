#!/usr/bin/env bash
# preview-asset-undo.sh — Offline preview of undoing an asset change.
#
# Usage:
#   scripts/apply-layer/preview-asset-undo.sh [reversal-id]
#
# Seeds a reversal registry with a snapshot (as an asset apply would have
# written) and runs gads-undo.sh against a stubbed API, so the restore path
# can be inspected without touching a live account.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REV_ID="${1:-rev-001}"

WORKDIR="$(mktemp -d)"
STUB_BIN="$WORKDIR/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/curl" <<'STUBEOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="${STUB_LOG:-/dev/null}"
METHOD=""; URL=""; BODY=""; WRITE_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--request) METHOD="$2"; shift 2 ;;
    -d|--data) BODY="$2"; shift 2 ;;
    --data) BODY="$2"; shift 2 ;;
    -w) WRITE_OUT="$2"; shift 2 ;;
    -H|--header) shift 2 ;;
    -o|--output) shift 2 ;;
    *) URL="$1"; shift ;;
  esac
done
{ echo "=== ${METHOD} ${URL}"; [ -n "$BODY" ] && { echo "--- body ---"; echo "$BODY"; }; echo ""; } >> "$LOG"
respond() { if [ -n "$WRITE_OUT" ]; then printf '%s\n%s\n' "$1" "$2"; else printf '%s\n' "$1"; fi; }
case "$URL" in
  *oauth2.googleapis.com/token) respond '{"access_token":"fake","expires_in":3600}' 200; exit 0 ;;
  *googleAds:searchStream) respond '[{"results":[]}]' 200; exit 0 ;;
  *adGroupAssets:mutate) respond '{"results":[{"resourceName":"customers/1234567890/adGroupAssets/444~999~SITELINK"}]}' 200; exit 0 ;;
  *) respond '{"results":[{"resourceName":"customers/1234567890/ads/555"}]}' 200; exit 0 ;;
esac
STUBEOF
chmod +x "$STUB_BIN/curl"

export STUB_LOG="$WORKDIR/requests.log"
: > "$STUB_LOG"
export GOOGLE_ADS_DEVELOPER_TOKEN="fake"
export GOOGLE_APPLICATION_CREDENTIALS="/nonexistent"

TOKEN_PATH="/tmp/gads-copilot-token.json"
TOKEN_BACKUP=""
if [ -f "$TOKEN_PATH" ]; then
  TOKEN_BACKUP="$WORKDIR/token.bak"
  cp "$TOKEN_PATH" "$TOKEN_BACKUP"
fi
jq -n --argjson e "$(( $(date +%s) + 3600 ))" '{access_token:"fake",expires_at:$e}' > "$TOKEN_PATH"
chmod 600 "$TOKEN_PATH"

cleanup() {
  if [ -n "$TOKEN_BACKUP" ]; then cp "$TOKEN_BACKUP" "$TOKEN_PATH"; else rm -f "$TOKEN_PATH"; fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

SANDBOX="$WORKDIR/sandbox"
mkdir -p "$SANDBOX/scripts" "$SANDBOX/workspace/ads/audit-trail" "$SANDBOX/workspace/ads/drafts"
cp -R "$SCRIPT_DIR" "$SANDBOX/scripts/apply-layer"

# A reversal record as an asset apply would have written it.
cat > "$SANDBOX/workspace/ads/audit-trail/reversal-registry.json" <<REGEOF
{
  "version": "1.0",
  "description": "Registry of all applied actions and their reversal instructions.",
  "reversals": [
    {
      "id": "${REV_ID}",
      "action": "UPDATE_RSA_ASSETS",
      "keyword": "-",
      "matchType": "N/A",
      "scope": "AD_GROUP",
      "campaignName": "High Intent - Search",
      "campaignId": "333",
      "accountId": "1234567890",
      "appliedAt": "2026-11-10T10:00:00+07:00",
      "appliedBy": "operator",
      "draftSource": "draft.md",
      "reversalAction": "RESTORE_RSA_ASSETS",
      "reversalResourceName": "customers/1234567890/ads/555",
      "resourceName": "customers/1234567890/ads/555",
      "beforeMicros": 0,
      "afterMicros": 0,
      "snapshot": {
        "headlines": [
          { "text": "Existing Headline One", "pinned_field": "HEADLINE_1" },
          { "text": "Existing Headline Two", "pinned_field": "" }
        ],
        "descriptions": [
          { "text": "Existing description text.", "pinned_field": "" }
        ],
        "final_urls": ["https://example.com/live"]
      },
      "createdAssetId": null,
      "status": "active",
      "undoneAt": null
    }
  ]
}
REGEOF

echo "══════════════════════════════════════════════════════════════════"
echo " OFFLINE UNDO PREVIEW — stubbed Google Ads API, no live account touched"
echo "══════════════════════════════════════════════════════════════════"
echo ""

printf 'confirm\n' | PATH="$STUB_BIN:$PATH" \
  bash "$SANDBOX/scripts/apply-layer/gads-undo.sh" "$REV_ID" 2>&1 | sed 's/^/  /'

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " RESTORE REQUEST THE UNDO WOULD SEND"
echo "══════════════════════════════════════════════════════════════════"
sed -n '/ads:mutate/,/^$/p' "$STUB_LOG"

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " REGISTRY STATUS AFTER UNDO"
echo "══════════════════════════════════════════════════════════════════"
jq '.reversals[] | {id, status, undoneAt}' "$SANDBOX/workspace/ads/audit-trail/reversal-registry.json"
