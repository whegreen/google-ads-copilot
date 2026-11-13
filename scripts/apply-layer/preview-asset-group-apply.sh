#!/usr/bin/env bash
# preview-asset-group-apply.sh — Offline preview of the v5 asset-group apply flow.
#
# Usage:
#   scripts/apply-layer/preview-asset-group-apply.sh <draft-file>
#
# Runs the real gads-apply.sh code path against a STUBBED Google Ads API, so
# the whole Performance Max flow (parse → resolve → merge → validate_only →
# execute → verify → audit) can be inspected without touching a live account.
#
# What is stubbed:
#   - OAuth2 token refresh                → returns a fake token
#   - googleAds:searchStream (GAQL)       → returns the campaign, the asset
#                                           group, the linked assets and their
#                                           texts from a local state file
#   - googleAds:mutate (bulk)             → applies the operations to that
#                                           state file, so the verify step
#                                           reads back what was written
#
# Every request the stub receives is written to $WORKDIR/requests.log so the
# exact payloads can be reviewed — that is the point of this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRAFT_FILE="${1:-}"
if [ -z "$DRAFT_FILE" ]; then
  echo "Usage: preview-asset-group-apply.sh <draft-file>" >&2
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
STATE="${STUB_STATE_DIR:-/tmp}"
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

respond() {
  # $1 = body, $2 = http code
  if [ -n "$WRITE_OUT" ]; then
    printf '%s\n%s\n' "$1" "$2"
  else
    printf '%s\n' "$1"
  fi
}

# Pull a literal value out of a GAQL WHERE clause, e.g.
#   campaign.name = 'tes 2'   →   tes 2
gaql_value() {
  local field="$1"
  printf '%s' "$BODY" | sed -nE "s/.*${field} = '([^']*)'.*/\1/p" | head -1
}

case "$URL" in
  *oauth2.googleapis.com/token)
    respond '{"access_token":"fake-token","expires_in":3600}' 200
    exit 0
    ;;

  *googleAds:searchStream)
    if [[ "$BODY" == *"FROM asset_group_asset"* ]]; then
      # The links of the asset group, from the local state file.
      respond "$(python3 "$STATE/links.py")" 200
    elif [[ "$BODY" == *"FROM asset "* ]] || [[ "$BODY" == *"FROM asset\n"* ]]; then
      # The texts of the assets that are linked.
      respond "$(python3 "$STATE/assets.py")" 200
    elif [[ "$BODY" == *"FROM asset_group"* ]]; then
      name="$(gaql_value 'asset_group\.name')"
      respond "[{\"results\":[{\"assetGroup\":{\"id\":\"6677194808\",\"name\":\"${name}\",\"status\":\"ENABLED\",\"finalUrls\":[\"https://kisahtumbuh.org/flexy-member\"]}}]}]" 200
    elif [[ "$BODY" == *"FROM campaign"* ]]; then
      name="$(gaql_value 'campaign\.name')"
      respond "[{\"results\":[{\"campaign\":{\"id\":\"333\",\"name\":\"${name}\"}}]}]" 200
    else
      respond '[{"results":[]}]' 200
    fi
    exit 0
    ;;

  *googleAds:mutate)
    # Apply the bulk operations to the local state, so the verify step reads
    # back what was written rather than the initial fixture.
    if [ -n "${STUB_STATE_DIR:-}" ]; then
      printf '%s' "$BODY" > "$STATE/mutate-body.json"
      python3 "$STATE/apply.py"
    fi
    respond '{"mutateOperationResponses":[]}' 200
    exit 0
    ;;

  *)
    echo "stub curl: unhandled URL: ${URL}" >&2
    exit 1
    ;;
esac
STUBEOF
chmod +x "$STUB_BIN/curl"

# ── State helpers (python keeps the state machine readable) ─
STUB_STATE_DIR="$WORKDIR/state"
mkdir -p "$STUB_STATE_DIR"

cat > "$STUB_STATE_DIR/state.py" <<'PYEOF'
import json
import os

STATE_DIR = os.environ["STUB_STATE_DIR"]
STATE_FILE = os.path.join(STATE_DIR, "state.json")


def load():
    if not os.path.exists(STATE_FILE):
        return {"assets": [], "links": []}
    with open(STATE_FILE) as fh:
        return json.load(fh)


def save(state):
    with open(STATE_FILE, "w") as fh:
        json.dump(state, fh)


def asset_text(state, asset_rn):
    for a in state["assets"]:
        if a["resource_name"] == asset_rn:
            return a["text"]
    return ""
PYEOF

cat > "$STUB_STATE_DIR/links.py" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["STUB_STATE_DIR"])
from state import load

state = load()
rows = [
    {
        "assetGroupAsset": {
            "resourceName": link["resource_name"],
            "asset": link["asset"],
            "fieldType": link["field_type"],
            "status": link["status"],
        }
    }
    for link in state["links"]
    if link["status"] == "ENABLED"
]
print(json.dumps([{"results": rows}]))
PYEOF

cat > "$STUB_STATE_DIR/assets.py" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["STUB_STATE_DIR"])
from state import load

state = load()
rows = [
    {"asset": {"id": a["id"], "textAsset": {"text": a["text"]}}}
    for a in state["assets"]
]
print(json.dumps([{"results": rows}]))
PYEOF

cat > "$STUB_STATE_DIR/apply.py" <<'PYEOF'
import json
import os
import sys

sys.path.insert(0, os.environ["STUB_STATE_DIR"])
from state import load, save

STATE_DIR = os.environ["STUB_STATE_DIR"]
with open(os.path.join(STATE_DIR, "mutate-body.json")) as fh:
    body = json.load(fh)

state = load()
next_id = max([int(a["id"]) for a in state["assets"]] + [1000]) + 1

# A validateOnly request changes nothing — the real API rejects it, the stub
# just skips it so the state reflects only what was actually written.
if body.get("validateOnly") is True:
    sys.exit(0)

for op in body.get("mutateOperations", []):
    if "assetGroupAssetOperation" in op:
        sub = op["assetGroupAssetOperation"]
        if "remove" in sub:
            for link in state["links"]:
                if link["resource_name"] == sub["remove"]:
                    link["status"] = "REMOVED"
        elif "create" in sub:
            create = sub["create"]
            # The link points at the temporary resource name used in the
            # request; the API resolves it to the asset that was just
            # created. The alias table keeps that mapping.
            asset_ref = create["asset"]
            final_rn = state.get("aliases", {}).get(asset_ref, asset_ref)
            asset_id = final_rn.rsplit("/", 1)[-1]
            text = ""
            for a in state["assets"]:
                if a["resource_name"] == final_rn:
                    text = a["text"]
            state["links"].append(
                {
                    "resource_name": create["assetGroup"]
                    + "~"
                    + asset_id
                    + "~"
                    + create["fieldType"],
                    "asset": final_rn,
                    "field_type": create["fieldType"],
                    "status": "ENABLED",
                }
            )
    elif "assetOperation" in op and "create" in op["assetOperation"]:
        create = op["assetOperation"]["create"]
        asset_id = str(next_id)
        next_id += 1
        temp_rn = create["resourceName"]
        final_rn = temp_rn.rsplit("/", 1)[0] + "/" + asset_id
        state.setdefault("aliases", {})[temp_rn] = final_rn
        state["assets"].append(
            {
                "id": asset_id,
                "resource_name": final_rn,
                "text": create["textAsset"]["text"],
            }
        )

save(state)
PYEOF

# The live state the stub starts from: an asset group with a few assets.
python3 - "$STUB_STATE_DIR" <<'PYEOF'
import json
import os
import sys

state_dir = sys.argv[1]
assets = [
    {"id": "5001", "resource_name": "customers/1234567890/assets/5001", "text": "Daycare Services"},
    {"id": "5002", "resource_name": "customers/1234567890/assets/5002", "text": "Child Day Care"},
    {"id": "5003", "resource_name": "customers/1234567890/assets/5003", "text": "Home Day Care"},
    {"id": "5004", "resource_name": "customers/1234567890/assets/5004", "text": "Peace of mind childcare. Book your trusted sitter now."},
    # The three descriptions the E1 prune draft removes (live texts, 265-day
    # window: 40 impressions, 0 clicks, 0 conversions between them).
    {"id": "5005", "resource_name": "customers/1234567890/assets/5005", "text": "Quality childcare, on your schedule. Book your sitter today!"},
    {"id": "5006", "resource_name": "customers/1234567890/assets/5006", "text": "Stress-free childcare. Book your trusted sitter now."},
    {"id": "5007", "resource_name": "customers/1234567890/assets/5007", "text": "Kurikulum Kisah Tumbuh fokus kemandirian & regulasi emosi"},
]
links = [
    {
        "resource_name": "customers/1234567890/assetGroupAssets/6677194808~5001~HEADLINE",
        "asset": "customers/1234567890/assets/5001",
        "field_type": "HEADLINE",
        "status": "ENABLED",
    },
    {
        "resource_name": "customers/1234567890/assetGroupAssets/6677194808~5002~HEADLINE",
        "asset": "customers/1234567890/assets/5002",
        "field_type": "HEADLINE",
        "status": "ENABLED",
    },
    {
        "resource_name": "customers/1234567890/assetGroupAssets/6677194808~5003~HEADLINE",
        "asset": "customers/1234567890/assets/5003",
        "field_type": "HEADLINE",
        "status": "ENABLED",
    },
    {
        "resource_name": "customers/1234567890/assetGroupAssets/6677194808~5004~DESCRIPTION",
        "asset": "customers/1234567890/assets/5004",
        "field_type": "DESCRIPTION",
        "status": "ENABLED",
    },
    {
        "resource_name": "customers/1234567890/assetGroupAssets/6677194808~5005~DESCRIPTION",
        "asset": "customers/1234567890/assets/5005",
        "field_type": "DESCRIPTION",
        "status": "ENABLED",
    },
    {
        "resource_name": "customers/1234567890/assetGroupAssets/6677194808~5006~DESCRIPTION",
        "asset": "customers/1234567890/assets/5006",
        "field_type": "DESCRIPTION",
        "status": "ENABLED",
    },
    {
        "resource_name": "customers/1234567890/assetGroupAssets/6677194808~5007~DESCRIPTION",
        "asset": "customers/1234567890/assets/5007",
        "field_type": "DESCRIPTION",
        "status": "ENABLED",
    },
]
with open(os.path.join(state_dir, "state.json"), "w") as fh:
    json.dump({"assets": assets, "links": links}, fh)
PYEOF

# ── Stub the token cache so no refresh call is needed ────────
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
export STUB_STATE_DIR
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

echo "══════════════════════════════════════════════════════════════════"
echo " OFFLINE PREVIEW — stubbed Google Ads API, no live account touched"
echo "══════════════════════════════════════════════════════════════════"
echo ""

# Run the real apply flow, but feed "confirm assets" on stdin so it proceeds
# past the human-confirmation gate. The API itself is stubbed.
# DEBUG=1 traces every command inside the apply flow (for debugging the stub).
printf 'confirm assets\n' | PATH="$STUB_BIN:$PATH" \
  bash ${DEBUG:+-x} "$SANDBOX/scripts/apply-layer/gads-apply.sh" "$SANDBOX/draft.md" 2>&1 | sed 's/^/  /'

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
  jq '.reversals[] | {id, action, reversalAction, reversalResourceName, assetGroupId, addedAssets, removedAssets, snapshot}' \
    "$SANDBOX/workspace/ads/audit-trail/reversal-registry.json"
else
  echo "(no reversal record written)"
fi

# ── Undo ─────────────────────────────────────────────────────
# The undo runs against the SAME stub state, so the result shows whether the
# asset group really goes back to its pre-change list.
echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " UNDO PREVIEW — restores the asset group to its pre-change list"
echo "══════════════════════════════════════════════════════════════════"
if [ -f "$SANDBOX/workspace/ads/audit-trail/reversal-registry.json" ]; then
  printf 'confirm\n' | PATH="$STUB_BIN:$PATH" \
    bash "$SANDBOX/scripts/apply-layer/gads-undo.sh" rev-001 2>&1 | sed 's/^/  /'
else
  echo "(skipped — nothing to undo)"
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo " ASSET GROUP STATE AFTER THE UNDO"
echo "══════════════════════════════════════════════════════════════════"
python3 - "$STUB_STATE_DIR" <<'PYEOF'
import json
import os
import sys

state_dir = sys.argv[1]
with open(os.path.join(state_dir, "state.json")) as fh:
    state = json.load(fh)

by_type = {}
for link in state["links"]:
    if link["status"] == "ENABLED":
        by_type.setdefault(link["field_type"], []).append(link)

for field_type in ("HEADLINE", "LONG_HEADLINE", "DESCRIPTION"):
    entries = by_type.get(field_type, [])
    print(f"{field_type}: {len(entries)} linked")
    for entry in entries:
        text = ""
        for asset in state["assets"]:
            if asset["resource_name"] == entry["asset"]:
                text = asset["text"]
        print(f"  - {text}")
PYEOF
