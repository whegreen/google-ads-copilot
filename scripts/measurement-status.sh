#!/usr/bin/env bash
# measurement-status.sh — one command for the whole measurement period.
#
# The ad account is waiting for a measurement it does not have yet: the GTM
# tags are not published, so `WA Click` counts nothing and every asset
# decision has to be guessed. This script reports where that stands, so the
# operator does not have to remember which of the four gates to run.
#
# Usage:
#   bash scripts/measurement-status.sh
#
# Exit codes:
#   0  every gate passed
#   1  at least one gate is not met yet (this is the normal state today)
#   2  something could not be checked at all

set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

FAILED=0
SECTION=0

section() {
  SECTION=1
  printf '\n%s\n' "$1"
}

printf '==============================================================================\n'
printf ' Measurement status — account 9432618196 · asset group 6677194808\n'
printf '==============================================================================\n'

# ── 1. is the GTM container publishing the tags? ──
section '1. GTM container (GTM-KBFWRCMC) — are the conversion tags published?'
if python3 scripts/check-gtm-tags.py; then
  GTM_OK=1
else
  GTM_OK=0
  FAILED=1
fi

# ── 2. does the live site still carry the tracking? ──
section '2. Live site — snippet + dataLayer + whatsapp_clicked'
if bash scripts/verify-deploy-tracking.sh; then
  SITE_OK=1
else
  SITE_OK=0
  FAILED=1
fi

# ── 3. the F2 gate — is there enough measurement to act on? ──
section '3. F2 gate — is WA Click measurable yet?'
python3 scripts/verify-asset-performance.py --f2
F2_OK=$?
[[ $F2_OK -eq 0 ]] || FAILED=1

# ── 4. summary ──
section '4. Where this stands'
if [[ $GTM_OK -eq 1 ]]; then
  printf '   ✅ GTM container publishes the tags\n'
else
  printf '   ⏳ GTM tags NOT published — create them in the GTM UI, Submit → Publish,\n'
  printf '      then re-run this script. No code change is needed: the snippet and\n'
  printf '      the dataLayer push are already live.\n'
fi
if [[ $SITE_OK -eq 1 ]]; then
  printf '   ✅ Live site carries the tracking\n'
else
  printf '   ❌ Live site is missing part of the tracking — check the deploy\n'
fi
if [[ $F2_OK -eq 0 ]]; then
  printf '   ✅ F2 gate met — asset experiments may start\n'
else
  printf '   ⏳ F2 gate not met — no asset write happens yet (decision D4, 2026-11-12)\n'
fi

printf '\n'
if [[ $FAILED -eq 0 ]]; then
  printf '✅ everything is in place\n'
else
  printf '⏳ not there yet — the sequence is: publish the tags → wait for the\n'
  printf '   measurement to accumulate → then the asset experiments.\n'
fi
exit "$FAILED"
