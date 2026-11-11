# Changelog

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
  - `fetch_asset_group_text_assets()` — read live headlines / long headlines / descriptions of an asset group
  - `mutate_create_text_asset()` + `mutate_link_asset_group_asset()` — create a text asset and link it into the asset group
  - `mutate_set_asset_group_final_urls()` — change where the ad points
- `scripts/check-v25-queries.py` — extracts every GAQL query in the repo and runs it against the live API, so field drift is caught before it breaks a workflow
- `scripts/asset-group-inventory.py` — asset inventory + duplicate + language analysis for an asset group
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
