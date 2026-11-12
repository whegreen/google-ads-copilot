# Changelog

## Unreleased — Measurement gates: GTM publish check, per-asset performance, F2 scorecard

### Added
- **`scripts/gtm-publish.py`** — creates the Google Ads conversion tags in a GTM container through the Tag Manager API v2: resolves the account and workspace, snapshots the live container version (that snapshot is the rollback — publishing it again restores the previous state), makes sure a Custom Event trigger fires on `whatsapp_clicked`, creates the Conversion Linker and the Google Ads Conversion Tracking tag with the right conversion id, label, value and currency, **validates the result with `workspaces:quick_preview` before publishing**, then `workspaces:create_version` + `versions:publish` and reads the published version back. Nothing is written to the live container until `--publish` is passed; the default run is a dry run.
- **`scripts/check-gtm-scope.py`** — checks which OAuth scopes an OAuth client advertises. The authorization endpoint rejects a scope the client does not advertise with `invalid_scope`, and it does so *before* asking anyone to sign in, so a plain request is enough to test the client's scope list. That turns "add the scope, re-run the login, read the error" into a one second check — the loop that otherwise costs a human a click per attempt.
- **`scripts/check-gtm-tags.py`** — read-only publish gate for the GTM container. It fetches the compiled container (`gtm.js?id=GTM-KBFWRCMC`) and checks that the conversion id `AW-17023304515`, the WA Click label `BypDCOiCi7YdEMOGrLU_` and the trigger event `whatsapp_clicked` are actually served. The container file also contains GTM's own runtime (the strings "CustomEvent", "GoogleTag", "gclid" are built-in function names), so those are never used as markers. Baseline measured 2026-11-12: all three markers absent — the tags are not published yet. `--site` additionally checks the live page for the GTM snippet, the absence of `gtag('config'` beside it, and the dataLayer push in the active bundle; `--json` gives machine-readable output.
- **`scripts/verify-asset-performance.py`** — per-asset Performance Max performance from `asset_group_asset` + metrics: impressions, clicks, CTR and serving period per asset, the live slot usage against the published caps, and near-duplicate detection between linked texts (word overlap ≥ 0.40). `--f2` prints the weekly scorecard for the measurement gate — `WA Click` conversions, the `WA Click rate` and the `Clicks to call` proxy the campaign currently optimises for — and applies the locked gate (≥10 WA Click conversions in the window, rate stable for ≥3 consecutive weeks).
- **`scripts/verify-deploy-tracking.sh`** — post-deploy gate: the GTM snippet is present in the live page, no `gtag('config'` next to it, and the active bundle still contains `dataLayer.push` and `whatsapp_clicked`. A deploy that silently drops the dataLayer push looks fine in a browser and breaks every conversion measurement without an error.
- **`scripts/measurement-status.sh`** — one command for the whole measurement period: is the GTM container publishing the tags, does the live site still carry the tracking, and is the F2 gate met yet. The measurement itself takes months (budget is IDR 1.300/day, so ~1–2 WA clicks per week), so the operator needs a single status board rather than four scripts to remember.
- **`requirements-dev.txt` + a README section** — the nine scripts that use the official Google Ads client library could not run at all: on Python 3.15 pip resolves `google-ads` to 22.0.0, which needs `pkg_resources` (removed in setuptools 81) and protobuf's upb extension does not build on 3.14+. With Python 3.11–3.13 and `google-ads>=35` (which ships the v23–v26 API modules, so the client can reach the v25 endpoint this repo uses) all nine run again.

### Corrected
- `scripts/pmax_analysis.py` and `scripts/tracking_check.py` printed every amount with a `$` sign although the account currency is IDR — "Cost: $330643.68" read as a third of a million dollars for a campaign that spent Rp 330.644. Amounts are now printed as `IDR <amount>`.
- The slot cap reported by `verify-asset-performance.py` is the **published** cap, and the output says so: the enforced ceiling is higher and differs per asset group (this one accepted 16 headline links and 8 description links, and rejected the next description with `RESOURCE_LIMIT`). `validateOnly` stays the only authority — the same principle the apply layer already follows.

## Unreleased — Apply Layer v5: Performance Max Asset Group Writes

### Added
- **`UPDATE_ASSET_GROUP_ASSETS` apply action** — add, replace or unlink text assets (headlines, long headlines, descriptions) in one Performance Max asset group. The focused account is PMax-only (zero ad groups), so without this action type every asset draft on it failed to resolve a target.
- Apply Manifest schema **v0.4** (v0.3 and v0.2 stay valid) — adds `targets.asset_group_name`, `targets.long_headlines`, `targets.remove_assets` (`{text, field_type}`) and `targets.replace`.
- `lib/api-verify.sh` — `fetch_asset_group_assets()` reads the live links of an asset group (text, asset id, link resource name) plus the per-field-type link totals; `verify_asset_group_assets()` checks that every expected text is live in its own field type and that every removed text is gone. It supersedes `fetch_asset_group_text_assets()`, which returned the texts but not the link resource names a removal needs.
- `lib/api-mutate.sh` — `mutate_asset_group_bulk()` (one `googleAds:mutate` request carrying removals + create/link of every new asset) and `mutate_asset_group_remove()`.
- `lib/asset-rules.sh` — `asset_group_validate_action()`, `asset_group_merge_lists()`, `asset_group_validate_removals()`, `asset_group_slot_report()`.
- `gads-undo.sh` — `RESTORE_ASSET_GROUP_ASSETS`: unlinks what the action added and re-creates what it unlinked.
- `scripts/apply-layer/preview-asset-group-apply.sh` — offline preview of the whole Performance Max flow (apply → verify → audit → undo) against a stubbed API with a simulated asset-group state.
- `gads-apply.sh --validate-only` — runs the draft against the **live** account with `validateOnly` and changes nothing. This is the only gate that knows the account's real slot limits.
- 17 eval cases (`evals/apply_cases.json`) and a shell-regression block covering the asset-group rules, the manifest parsing, the bulk payload and the offline apply/undo cycle.

### Changed
- **Slot limits are advisory locally.** The API's real ceiling for an asset group does not match the published caps and differs between asset groups of the same type — measured on account 9432618196: asset group 6677194808 accepted 16 headline links, 6654057973 accepted 15, 6677269312 rejected a 16th. A hard-coded local cap would either block a change the API accepts or allow one it rejects, so the local count is now a report and `validateOnly` is the fail-closed gate.
- **Removal is explicit, per asset name.** A draft names the exact texts to unlink in `remove_assets`; the layer never picks an asset to drop on its own. A removal needs `acknowledge_learning_period: true`, and a name that is not live is an error (`remove_asset_not_found`) rather than a silent no-op.
- The same text may not be removed and added in one draft (`remove_and_add_same_text`) — the asset group's text is immutable, so that combination is contradictory.

### Corrected
- The 2026-11-11 PMax asset-fill draft claimed the description slot had room for two more descriptions. It does not: the asset group carries 8 description link rows and the API rejects an added description with `RESOURCE_LIMIT`. The draft was revised — Changes 1 and 2 (7 headlines, 2 long headlines) are executable, Change 3 (descriptions) is marked not executable and Change 4 (removing English-description noise) stays blocked until per-asset performance labels exist.
- The PMax slot table in that draft was wrong on two counts: descriptions are capped at 5 (not 4), and the previous version used the published caps as if they were the enforced ones.

## Unreleased — API v25 Migration + MegaMemory Dev-Token Sunset

### Changed
- **API version v20 → v25.** v18–v21 now return 404 (sunset) and v22 returns 400; every read and write from this repo was failing.
- **Developer token no longer required.** Tokens were sunset 2026-09-09 — API access is now bound to the Google Cloud project that owns the OAuth credentials. The `developer-token` header is only sent when `GADS_SEND_DEVELOPER_TOKEN=true`.
- Field renames applied across all queries: `asset_group.final_url` → `final_urls`, `landing_page_view.final_url` → `unexpanded_final_url`, `asset.image_asset.full_size_image_url` → `full_size.url`, `ad_group_ad.id` → `resource_name`, `ad_group_asset.asset.id` → `asset`.
- Resources removed from the API in v25 replaced: `asset_group_audience` → `audience`, `customer_negative_keyword` → `customer_negative_criterion`. `search_theme` was removed outright — PMax search themes are no longer readable.
- `campaign_criterion.device.type` now filtered with `IN (...)` — `IS NOT NULL` is not valid on an enum field.
- `conversion_action` can no longer be combined with `metrics.conversions` in one query (`PROHIBITED_METRIC_IN_SELECT_OR_WHERE_CLAUSE`); configuration and performance are now separate queries.

### Added
- **Performance Max asset group support** in the apply layer — this account is PMax-only and has zero ad groups, so the previous Search-RSA path could never resolve a target:
  - `lookup_asset_group()` — resolve a PMax asset group by campaign + name (the asset group is where PMax final URLs live)
  - `fetch_asset_group_text_assets()` — read live headlines / long headlines / descriptions of an asset group (removed in Apply Layer v5 below, superseded by `fetch_asset_group_assets()`)
  - `mutate_create_text_asset()` + `mutate_link_asset_group_asset()` — create a text asset and link it into the asset group
  - `mutate_set_asset_group_final_urls()` — change where the ad points
- `scripts/check-v25-queries.py` — extracts every GAQL query in the repo and runs it against the live API, so field drift is caught before it breaks a workflow
- `scripts/asset-group-inventory.py` — asset inventory + duplicate + language analysis for an asset group
- `scripts/verify-asset-group-assets.py` — read-only confirmation of an asset group's live slot usage and contents (enabled counts, link rows incl. REMOVED, duplicates, texts); `--expected <file.json` diffs the live lists against a snapshot and exits 1 on mismatch. This is gate 6 of the apply-layer v5 plan.
- `workspace/ads/assets.md` — live asset inventory with slot usage and duplicate check
- `workspace/ads/goals.md` — business goals, catalogue, funnel map, guardrails, open questions

### Fixed
- `_gads_headers` emitted whole `-H "Name: value"` strings, so curl received them as one malformed argument instead of a header pair
- A malformed asset draft could pass pre-flight validation
- `verify_adgroup_asset_exists` now fails with a clear message instead of querying an empty asset id

### Corrected
- The 2026-11-10 PMax Structure Fix draft analysed **removed** asset groups, not the live one. Asset group 6677194808 has 18 text assets and **zero duplicates** — the problem is under-filled slots and copy that names only 2 of 7 catalogue services, not duplication. Superseded by `2026-11-11-temateyang-pmax-asset-fill.md`; the old draft is kept and marked superseded.

## Unreleased — Apply Layer v3: Ad Assets Without UI

### Added
- `UPDATE_RSA_ASSETS` apply action — add or replace RSA headlines and descriptions on one ad group
- `CREATE_ADGROUP_ASSET` apply action — create sitelink, callout, or structured snippet and link it to an ad group
- Apply Manifest schema v0.3 (v0.2 still accepted for budget-only drafts)
- `lib/asset-rules.sh` — shared asset validation and merge rules (no API access, unit-tested from the eval suite)
- `scripts/apply-layer/preview-asset-apply.sh` — offline preview of the asset apply flow against a stubbed API
- `scripts/apply-layer/preview-asset-undo.sh` — offline preview of undoing an asset change
- `evals/fixtures/draft-asset-manifest.md` — asset draft fixture
- 20 new eval cases covering asset parser, guardrails, merged-list rules, and merge semantics

### Safety model
- Read-modify-write: the live asset list is read before every update, because the API replaces the whole list on mutation
- `validateOnly` dry run before every asset mutation — limits, pin rules, and duplicate-text checks run against the live account without changing it
- Snapshot-based reversal — the pre-change asset list is stored and restored on undo (performance history of removed assets is not recoverable, and the undo says so)
- Blast-radius guard — an asset action may only touch an ad group the draft names explicitly
- Separate confirmation phrase (`confirm assets`) distinct from budgets

### Fixed
- `gads-undo.sh` crashed on an undefined `DIM` colour variable
- Asset lookups read the wrong GAQL response path, so `ad_id` resolved to null

## 0.4.0 — Public Alpha (Builder Preview) — 2026-03-15

### Highlights
- **All three layers are live.** Read → Draft → Apply — the full architecture is operational with real write-back to Google Ads API v20.
- **Publish-prep polish pass.** Public-facing materials sanitized, demo workflow defined, examples curated.

### Apply Layer (v1)
- CLI scripts for safe write-back: `gads-apply.sh`, `gads-undo.sh`, `gads-review.sh`, `gads-status.sh`, `gads-smoke-test.sh`
- v1 scope: add negative keywords (campaign + ad group), pause keywords, pause ad groups
- Full safety model: dry run → human confirm → execute → GAQL verify → audit trail → reversal registry
- Bash + curl + jq only — no Python/Node runtime dependency
- API v20 (v18 sunset, v19 unstable)
- End-to-end write cycle proven on live accounts

### New Skills
- `google-ads-apply` — safe write execution with draft parsing
- `google-ads-draft-summary` — prioritized summary of all pending drafts with apply order
- `google-ads-landing-review` — landing page → conversion path diagnosis (Two-Fork model: tracking vs UX)

### New Documents
- `OPERATOR-PLAYBOOK.md` — full operator workflow loop (connect → apply → undo)
- `DEMO-WORKFLOW.md` — blessed happy-path walkthrough for demos and onboarding
- `PUBLISH-CHECKLIST.md` — sanitization and release checklist

### Infrastructure
- `.gitignore` — covers credentials, live workspace data, internal-only files
- `examples/internal/` — real-account test examples separated from public-facing examples
- Sanitized all public-facing docs (README, OPERATOR-PLAYBOOK, ARCHITECTURE, examples)

### Pause Support
- Keyword pause + ad group pause fully scaffolded (parser, template, validation, verification)
- Pause draft template: `drafts/templates/pause-draft.md`

---

## 0.3.0 — Connected Mode Live Testing — 2026-03-14

### Highlights
- First live connected-mode tests against real Google Ads accounts
- Intent Map validated on real data — confirmed as most valuable artifact
- Connected-mode onboarding via `google-ads-connect` skill

### Connected Mode
- `google-ads-connect` skill: first-time setup, health check, account selection
- Customer discovery via `list_accessible_customers`
- Account fingerprint written to `workspace/ads/account.md`
- Date range fallback chain: LAST_30_DAYS → LAST_90_DAYS → LAST_12_MONTHS → all time
- `keyword_view` supplementation alongside `search_term_view`
- PMax search-term fallback documentation + probe script using `campaign_search_term_view`
- `campaign_search_term_insight` caveat documented: requires filtering to a single campaign id

### Intent Map Validation
- Tested against real accounts in connected mode
- Framework transfers well across industries (SaaS, local services, B2B equipment)
- Structural implications section is the key differentiator
- Documented as the most valuable analytical artifact in the package

### Tracking Confidence
- Explicit threshold rubric with decision matrix
- Tracking confidence gates budget/bid decisions (LOW/BROKEN blocks scaling)
- Conv:all_conv ratio threshold (2x = healthy)
- Store visit pollution detection

### Negative Lifecycle
- Three-section template: Add, Remove, Narrow/Move
- Catches harmful existing negatives
- Keyword cross-referencing: identifies which keywords generate waste

### Landing Page Diagnosis
- Two-Fork model: Fork A (tracking broken?) → Fork B (UX broken?)
- Scenario classification: tracking-only, UX-only, both, traffic quality
- Conversion path walking: traces click → landing → CTA → form → conversion

---

## 0.2.0 — Three-Layer Wiring

### Highlights
- Defined Read → Draft → Apply three-layer architecture
- All skills wired with connected + export mode
- Draft system with templates, lifecycle, and queue

### Architecture
- `ARCHITECTURE.md` — full design document
- Connected mode: GAQL queries via `googleads/google-ads-mcp` MCP server
- Export mode: graceful fallback to CSV/paste data
- Draft system: templates, lifecycle, index, dependency tracking

### Skills
- All 11 original skills updated with data acquisition + draft output
- Orchestrator updated with data + draft protocols
- Tracking confidence flows through to gate budget decisions

### Data Layer
- `data/mcp-config.md` — MCP server setup instructions
- `data/gaql-recipes.md` — GAQL query library per skill
- `data/export-formats.md` — manual export specifications

---

## 0.1.0 — Initial Package

- Package skeleton with orchestrator and core skills
- Reference playbooks: operator thesis, intent map, query patterns, negatives, tracking, structure, RSA, budget
- Workspace memory templates
- Eval scaffold
- Specialist agents
