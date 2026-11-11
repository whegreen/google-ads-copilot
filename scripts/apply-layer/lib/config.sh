#!/usr/bin/env bash
# config.sh — Shared configuration for the apply layer
#
# Source this file from all apply-layer scripts.
# Single source of truth for API version, base URL, and common settings.

# Google Ads REST API version
# Updated 2026-11-11: v18/v19/v20 sunset (404), v21 sunset (404), v22 rejects
# requests (400). v25 confirmed working against the live production account.
# Keep this on the newest version the account's Cloud project access allows.
GADS_API_VERSION="v25"
GADS_API_BASE="https://googleads.googleapis.com/${GADS_API_VERSION}"

# Developer tokens were sunset 2026-09-09. API access levels are now bound to
# the Google Cloud project that owns the OAuth credentials, and the
# `developer-token` header is ignored by the API servers. We stop sending it
# because a future major version will start rejecting it.
# https://developers.google.com/google-ads/api/docs/api-policy/developer-token
GADS_SEND_DEVELOPER_TOKEN="false"

# Rate limiting
GADS_MUTATION_DELAY_MS=500    # Delay between mutations (milliseconds)
GADS_MAX_ACTIONS_PER_SESSION=50

# Token cache location
GADS_TOKEN_CACHE="/tmp/gads-copilot-token.json"

# Escape a string for safe use in GAQL WHERE clauses
# Handles single quotes by doubling them (GAQL escaping)
_gaql_escape() {
  local input="$1"
  echo "${input//\'/\'\'}"
}

# Portable ISO-8601 timestamp helper.
gads_now_iso() {
  if date -Iseconds >/dev/null 2>&1; then
    date -Iseconds
  else
    date +"%Y-%m-%dT%H:%M:%S%z" | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'
  fi
}

# Parse an ISO-8601 timestamp to epoch seconds across GNU/BSD date.
gads_epoch_from_iso() {
  local timestamp="$1"
  local bsd_timestamp

  bsd_timestamp=$(printf '%s\n' "$timestamp" | sed -E 's/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')

  if date -d "$timestamp" +%s >/dev/null 2>&1; then
    date -d "$timestamp" +%s
    return 0
  fi

  if date -j -f "%Y-%m-%dT%H:%M:%S%z" "$bsd_timestamp" +%s >/dev/null 2>&1; then
    date -j -f "%Y-%m-%dT%H:%M:%S%z" "$bsd_timestamp" +%s
    return 0
  fi

  if date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" +%s >/dev/null 2>&1; then
    date -j -f "%Y-%m-%dT%H:%M:%S" "$timestamp" +%s
    return 0
  fi

  echo 0
}

# Read the value of the first markdown bullet matching "- Key: Value".
gads_markdown_field() {
  local file="$1"
  local label="$2"

  awk -v label="$label" '
    index($0, "- " label ":") == 1 {
      value = substr($0, length(label) + 4)
      sub(/^[[:space:]]+/, "", value)
      print value
      exit
    }
  ' "$file"
}

# Read the first non-empty line immediately after a markdown heading.
gads_heading_body_line() {
  local file="$1"
  local heading="$2"

  awk -v heading="$heading" '
    $0 == heading { capture = 1; next }
    capture && NF {
      print
      exit
    }
  ' "$file"
}
