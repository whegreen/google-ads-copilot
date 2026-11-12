#!/usr/bin/env bash
# verify-deploy-tracking.sh — post-deploy gate for the conversion path.
#
# The GTM tags are configured in the GTM UI, but the site side is code: after
# a deploy the live bundle must still push `whatsapp_clicked` into the
# dataLayer, and the GTM snippet must still be in the page. A deploy that
# silently drops either one looks fine in the browser and breaks every
# conversion measurement without any error.
#
# Read-only: it fetches the live site and reports what is actually served.
#
# Usage:
#   bash scripts/verify-deploy-tracking.sh
#   bash scripts/verify-deploy-tracking.sh https://www.kisahtumbuh.org
#
# Exit codes:
#   0  every check passed
#   1  at least one check failed
#   2  the site could not be fetched

set -uo pipefail

SITE="${1:-https://www.kisahtumbuh.org}"
CONTAINER="${GTM_CONTAINER:-GTM-KBFWRCMC}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

FAILED=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf '   ✅ %s\n' "$1"; }
fail() {
  printf '   ❌ %s\n' "$1"
  FAILED=1
}
info() { printf '   ·  %s\n' "$1"; }

printf '==============================================================================\n'
printf ' Deploy tracking gate — %s\n' "$SITE"
printf '==============================================================================\n'

# ── 1. the page ──
if ! curl -sSf -A "$UA" "$SITE/" -o "$TMP/index.html"; then
  printf '❌ could not fetch %s/\n' "$SITE" >&2
  exit 2
fi

if grep -q "$CONTAINER" "$TMP/index.html"; then
  pass "GTM snippet present (container $CONTAINER)"
else
  fail "GTM snippet missing from index.html (expected $CONTAINER)"
fi

# gtag.js beside GTM would double-tag every page: GTM already runs the
# Conversion Linker, so a second config would fire conversions twice.
if grep -q "gtag('config'" "$TMP/index.html"; then
  fail "index.html contains gtag('config') — double-tagging next to GTM"
else
  pass "no gtag('config') next to GTM"
fi

# ── 2. the bundle ──
BUNDLE="$(grep -o '/assets/index-[A-Za-z0-9_-]*\.js' "$TMP/index.html" | head -1)"
if [[ -z "$BUNDLE" ]]; then
  fail "no active bundle found in index.html"
  printf '\n❌ deploy tracking gate FAILED\n'
  exit 1
fi
info "active bundle: $BUNDLE"

if curl -sSf -A "$UA" "${SITE}${BUNDLE}" -o "$TMP/bundle.js"; then
  if grep -q "dataLayer.push" "$TMP/bundle.js"; then
    pass "bundle pushes to the dataLayer"
  else
    fail "bundle has no dataLayer.push — the GTM container sees no events"
  fi

  if grep -q "whatsapp_clicked" "$TMP/bundle.js"; then
    pass "bundle contains the whatsapp_clicked event"
  else
    fail "bundle has no whatsapp_clicked — the WA click cannot be counted"
  fi

  if grep -q "wa\.me" "$TMP/bundle.js"; then
    pass "bundle contains the WhatsApp links"
  else
    info "bundle has no wa.me link — check whether the CTA changed"
  fi
else
  fail "could not fetch $BUNDLE"
fi

printf '\n'
if [[ "$FAILED" -eq 0 ]]; then
  printf '✅ deploy tracking gate PASSED\n'
  printf '   Next: check the GTM container itself — python3 scripts/check-gtm-tags.py\n'
  exit 0
fi
printf '❌ deploy tracking gate FAILED\n'
exit 1
