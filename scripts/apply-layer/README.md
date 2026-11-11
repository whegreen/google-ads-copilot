# Apply Layer — CLI Scripts

## Status: LIVE — Write Access Confirmed
API v25 confirmed working (v18–v21 sunset/404, v22 400).
Full write cycle proven on a live account.

## Architecture

These scripts implement the Google Ads Copilot apply layer: the safe-write path
from approved drafts to real Google Ads API mutations.

**v1 scope (default):** Add negative keywords + pause keywords/ad groups.

**v2 scope (budget):** Set campaign daily budgets with hard guardrails (max % change, cooldowns, tracking gate, budget-neutral default).
Budget actions require an `## Apply Manifest` JSON block (see `drafts/ACTION-MANIFEST.md`).

**v3 scope (assets):** Update RSA text assets (headlines/descriptions) and create extension assets (sitelink, callout, structured snippet).
Also requires an `## Apply Manifest` JSON block (schema v0.3).

**v5 scope (Performance Max):** Add, replace or unlink text assets inside a
Performance Max asset group (`UPDATE_ASSET_GROUP_ASSETS`, manifest schema
v0.4). This account is PMax-only — it has zero ad groups — so without this
action type the apply layer could never resolve a target here.

Asset writes are the first apply actions that change what customers actually
see, so they carry extra guardrails:

- **Read-modify-write.** The Google Ads API replaces the *entire* headline and
  description list on update. The apply layer reads the live assets first and
  merges, so `replace: false` never drops an asset that is already serving.
- **Server-side validation.** Every asset mutation is sent once with
  `validateOnly: true` before the real call — limits, pin rules and
  duplicate-text checks run against the real account without changing it.
- **Snapshot reversal.** The pre-change asset list is stored in the reversal
  registry. Undo restores that exact list. Performance history of removed
  assets is *not* recoverable — the undo says so out loud.
- **Blast-radius guard.** An asset action may only touch an ad group the draft
  names explicitly, and it needs its own `confirm assets` confirmation.

### Performance Max asset groups specifically

A Performance Max asset group is not an ad group, and its rules differ:

- **Asset text is immutable.** Changing a headline means creating a NEW asset
  and linking it. The old asset is unlinked, and with it its performance
  history.
- **One bulk request.** The API does not resolve a temporary resource name
  (`assets/-1`) across separate calls, so every create+link pair and every
  removal rides in ONE `googleAds:mutate` request.
- **Removal is explicit.** A draft names the exact texts to unlink in
  `remove_assets`. The layer never picks an asset to drop on its own, and a
  removal needs `acknowledge_learning_period: true`.
- **Slot limits are advisory locally.** The API's real ceiling for an asset
  group does not match the published caps and differs between asset groups of
  the same type (measured: 16 headline links accepted in one asset group, 15
  in another). So the local count is a report, and the `validateOnly` request
  is the gate — it fails closed.


### Flow

```
┌──────────────┐     ┌──────────┐     ┌─────────┐     ┌─────────┐     ┌────────┐     ┌───────┐
│ parse-draft  │ ──► │ dry-run  │ ──► │ approve │ ──► │ execute │ ──► │ verify │ ──► │ audit │
│ (read .md)   │     │ (show)   │     │ (human) │     │ (API)   │     │ (GAQL) │     │ (log) │
└──────────────┘     └──────────┘     └─────────┘     └─────────┘     └────────┘     └───────┘
```

### Scripts

| Script | Purpose |
|--------|---------|
| `gads-apply.sh` | Main entry point — orchestrates the full apply flow |
| `gads-undo.sh` | Reverse a single action or full draft |
| `gads-review.sh` | Review a draft without applying — action breakdown + risk |
| `gads-status.sh` | Operator state overview — connection, drafts, reversals |
| `gads-auth.sh` | Get/refresh OAuth2 access token, test API connectivity |
| `gads-smoke-test.sh` | End-to-end write cycle test (`negative` or `budget` mode) |
| `preview-asset-apply.sh` | Offline preview of the asset apply flow against a stubbed API |
| `preview-asset-undo.sh` | Offline preview of undoing an asset change |
| `preview-asset-group-apply.sh` | Offline preview of the Performance Max asset-group flow (apply + undo) against a stubbed API |
| `lib/config.sh` | Shared config: API version, base URL, GAQL escaping helpers |
| `lib/parse-draft.sh` | Extract structured actions from draft markdown (negatives + pauses + assets) |
| `lib/asset-rules.sh` | Pure asset validation + merge rules (no API access) |
| `lib/api-mutate.sh` | Execute a single Google Ads API mutation |
| `lib/api-verify.sh` | Verify a mutation took effect via GAQL query + ID lookups |
| `lib/audit-write.sh` | Write audit trail entries |
| `lib/token-refresh.sh` | OAuth2 token refresh helper |

### Prerequisites

- `jq` — JSON processing
- `curl` — API calls
- OAuth2 credentials saved to a local file based on `data/google-ads-adc-authorized-user.template.json`
- Developer token: **not required** — sunset 2026-09-09. API access is bound to the Google Cloud project that owns the OAuth credentials. Set `GADS_SEND_DEVELOPER_TOKEN=true` only if you must talk to a pre-v25 endpoint.
- Account configured in `workspace/ads/account.md`

### Quick Start

```bash
# Create local credential/env files from the public templates
cp data/google-ads-adc-authorized-user.template.json data/google-ads-adc-authorized-user.json
cp data/google-ads-mcp.test.env.example.sh data/google-ads-mcp.test.env.sh

# Fill in your real values, then source the local env file
source data/google-ads-mcp.test.env.sh

# Check operator status (what's connected, pending, applied)
./scripts/apply-layer/gads-status.sh

# Run smoke test (proves write cycle works)
./scripts/apply-layer/gads-smoke-test.sh negative <YOUR_CID>
./scripts/apply-layer/gads-smoke-test.sh budget <YOUR_CID> [campaign_id]

# Check auth
./scripts/apply-layer/gads-auth.sh

# Review a draft without applying (no API calls)
./scripts/apply-layer/gads-review.sh workspace/ads/drafts/<your-draft>.md

# Review all pending drafts
./scripts/apply-layer/gads-review.sh --all

# Dry run only (resolves IDs via API but doesn't mutate)
./scripts/apply-layer/gads-apply.sh --dry-run workspace/ads/drafts/<your-draft>.md

# Preview the asset flow offline — stubbed API, no live account, no credentials
./scripts/apply-layer/preview-asset-apply.sh workspace/ads/drafts/<your-asset-draft>.md
./scripts/apply-layer/preview-asset-undo.sh rev-001

# Preview the Performance Max asset-group flow offline (apply + undo)
./scripts/apply-layer/preview-asset-group-apply.sh workspace/ads/drafts/<your-pmax-draft>.md

# Server-side validation against the LIVE account — validateOnly, no changes.
# This is the only gate that knows the account's real slot limits.
./scripts/apply-layer/gads-apply.sh --validate-only workspace/ads/drafts/<your-draft>.md

# Apply a draft (full flow: parse → validate → dry-run → confirm → execute → verify → audit)
./scripts/apply-layer/gads-apply.sh workspace/ads/drafts/<your-draft>.md

# List active reversals
./scripts/apply-layer/gads-undo.sh --list

# Undo a specific action
./scripts/apply-layer/gads-undo.sh rev-001

# Undo an entire draft
./scripts/apply-layer/gads-undo.sh --draft workspace/ads/drafts/<your-draft>.md
```

### Asset action confirmations

Asset writes ask for their own confirmation phrase, separate from budgets:

| Draft contains | Type to confirm |
|----------------|-----------------|
| Budget actions only | `confirm budgets` |
| Asset actions only | `confirm assets` |
| Both | `confirm budgets and assets` |
| Neither | `confirm` |

### API Version History

| Version | Status | Notes |
|---------|--------|-------|
| v18–v21 | ❌ 404 | Sunset — no longer accessible |
| v22 | ❌ 400 | Rejected |
| **v25** | ✅ 200 | **Current** — confirmed working 2026-11-11 |

The API version is centralized in `lib/config.sh`. To upgrade, change it once there.
`scripts/check-v25-queries.py` runs every GAQL query in the repo against the
live API, so field drift is caught before it breaks a workflow.

### Design Constraints

1. **bash + curl + jq only** — no Python/Node runtime dependency
2. **No MCP dependency for writes** — direct REST API (MCP is read-only today)
3. **Idempotent** — re-running on an already-applied draft skips applied actions
4. **Atomic logging** — audit trail written per-action, not batched
5. **Fail-forward** — one failed action doesn't block the rest
6. **GAQL-safe** — all query string values escaped via `_gaql_escape()`
7. **Manifest-first for new writes** — budget writes come from `## Apply Manifest`, with legacy markdown parsing kept for v1 draft types

### Public Repo Note

The repo intentionally excludes any real credential or test files. Only safe templates are committed:

- `data/google-ads-adc-authorized-user.template.json`
- `data/google-ads-mcp.test.env.example.sh`

Create your own local copies before running live tests.

### Supported Endpoints (v25)

| Endpoint | Operation | Status |
|----------|-----------|--------|
| `customers/{cid}/campaignCriteria:mutate` | CREATE (add campaign negative) | ✅ Tested |
| `customers/{cid}/campaignCriteria:mutate` | REMOVE (undo campaign negative) | ✅ Tested |
| `customers/{cid}/adGroupCriteria:mutate` | CREATE (add ad group negative) | ✅ Scaffolded |
| `customers/{cid}/adGroupCriteria:mutate` | UPDATE status→PAUSED (pause keyword) | ✅ Scaffolded |
| `customers/{cid}/adGroupCriteria:mutate` | UPDATE status→ENABLED (undo keyword pause) | ✅ Scaffolded |
| `customers/{cid}/adGroupCriteria:mutate` | REMOVE (undo ad group negative) | ✅ Scaffolded |
| `customers/{cid}/adGroups:mutate` | UPDATE status→PAUSED (pause ad group) | ✅ Scaffolded |
| `customers/{cid}/adGroups:mutate` | UPDATE status→ENABLED (undo ad group pause) | ✅ Scaffolded |
| `customers/{cid}/ads:mutate` | UPDATE RSA headlines/descriptions | ✅ Scaffolded |
| `customers/{cid}/assets:mutate` | CREATE text / extension asset | ✅ Scaffolded |
| `customers/{cid}/adGroupAssets:mutate` | CREATE + REMOVE asset link | ✅ Scaffolded |
| `customers/{cid}/googleAds:mutate` | Bulk create + link + unlink (Performance Max asset group) | ✅ Validated |
| `customers/{cid}/googleAds:searchStream` | GAQL queries (verify, lookup) | ✅ Tested |
| `customers:listAccessibleCustomers` | Account discovery | ✅ Tested |
