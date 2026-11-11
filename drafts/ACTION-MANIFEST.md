# Apply Manifest — Draft-to-Apply Contract

This document defines the machine-readable “Apply Manifest” format embedded in draft markdown files.

Goals:
- Provide a stable, evaluable contract between the Draft layer and Apply layer.
- Avoid brittle markdown parsing for new action types (budgets, RSA updates, etc.).
- Keep the apply layer implementation compatible with existing constraints (bash + curl + jq).
- Keep budget writes fail-closed unless the manifest explicitly opts into the allowed policy.

## Where It Lives In a Draft

Drafts MAY include an `## Apply Manifest` section with a fenced JSON block:

```markdown
## Apply Manifest

~~~json
{ ... }
~~~
```

Apply-layer parsing rules:
- If a valid manifest is present, it is authoritative (manifest-first).
- If no manifest is present, apply falls back to legacy v1 markdown parsing (negatives + pauses).
- If a manifest is present but invalid, apply MUST fail closed.

## Schema (v0.4)

Top-level object:
- `draft_version` (required): `"0.4"`
  - `"0.3"` is still accepted (RSA + extension assets).
  - `"0.2"` is still accepted for budget-only drafts (no asset actions).
- `customer_id` (required): 10-digit string
- `customer_name` (optional): string
- `meta` (optional): object for draft-level policy
- `actions` (required): array of action objects (must be non-empty)

Draft-level `meta.budget_policy` fields used by v2 budget apply:
- `allow_net_increase` (boolean, default `false`): permit a draft-level net budget increase
- `max_net_increase_pct` (integer, default `10`): maximum aggregate increase vs current total budget
- If `allow_net_increase` is omitted or false, the draft must be budget-neutral.

Action object (common fields):
- `id` (required): stable identifier, `^[a-z][a-z0-9_-]{1,31}$`
- `type` (required): action type enum (see below)
- `risk` (required): `"low" | "medium" | "high"`
- `reason` (required): short string (<= 240 chars)
- `depends_on` (optional): array of action ids
- `targets` (required): object; type-specific fields
- `guardrails` (optional): object; required for money-moving actions

## Action Types

### v1 Apply Types (existing)
- `ADD_NEGATIVE_CAMPAIGN`
  - `targets`: `{ "campaign_name": string, "keyword_text": string, "match_type": "PHRASE"|"EXACT"|"BROAD" }`
- `ADD_NEGATIVE_ADGROUP`
  - `targets`: `{ "campaign_name": string, "adgroup_name": string, "keyword_text": string, "match_type": "PHRASE"|"EXACT"|"BROAD" }`
- `PAUSE_KEYWORD`
  - `targets`: `{ "campaign_name": string, "adgroup_name": string, "keyword_text": string, "match_type": "PHRASE"|"EXACT"|"BROAD" }`
- `PAUSE_ADGROUP`
  - `targets`: `{ "campaign_name": string, "adgroup_name": string }`

### v2 Apply Types (budgets)
- `SET_CAMPAIGN_DAILY_BUDGET`
  - `targets`: `{ "campaign_name": string, "proposed_daily_budget_micros": integer }`
  - `guardrails` (required by v2 apply implementation):
    - `max_pct_change` (integer, default 30)
    - `cooldown_days` (integer, default 7)
    - `require_budget_neutral` (boolean, default true)
    - `tracking_min_confidence` (`"medium"` default)

### v3 Apply Types (ad assets)

Assets are what actually renders in the ad: RSA headlines/descriptions, and
extensions (sitelinks, callouts, structured snippets).

#### `UPDATE_RSA_ASSETS`
Adds or replaces RSA text assets on one ad group.

- `targets`:
  - `campaign_name` (string, required)
  - `adgroup_name` (string, required)
  - `final_urls` (array of string, required, ≥1) — must carry an `http://` or `https://` prefix
  - `headlines` (array, required): `{ "text": string, "pinned_field": string|null }`
    - `text` ≤ 30 characters
    - `pinned_field` ∈ `HEADLINE_1` \| `HEADLINE_2` \| `HEADLINE_3` (optional)
  - `descriptions` (array, required): `{ "text": string, "pinned_field": string|null }`
    - `text` ≤ 90 characters
    - `pinned_field` ∈ `DESCRIPTION_1` \| `DESCRIPTION_2` (optional)
  - `replace` (boolean, default false)
    - `false` → merge with the assets already live (new assets only)
    - `true` → the lists in this action ARE the final list (old assets are dropped)
- `guardrails`:
  - `max_assets_per_draft` (integer, default 10) — total headline+description count across the draft
  - `acknowledge_learning_period` (boolean, default false) — must be `true` when `replace: true`
  - `require_explicit_ad_group` (boolean, default true) — the ad group must be named in the draft

**Why `replace` matters.** The Google Ads API replaces the *entire* headline
and description list when you update an RSA. The apply layer therefore reads
the live assets first and merges, so `replace: false` never drops an asset
that is already serving.

**Why `acknowledge_learning_period` is required for `replace: true`.**
Dropping assets resets ad strength and can drop CTR for a while. A draft that
removes live assets must say so explicitly.

#### `CREATE_ADGROUP_ASSET`
Creates an extension asset and links it to one ad group.

- `targets`:
  - `campaign_name` (string, required)
  - `adgroup_name` (string, required)
  - `asset_type` (string, required): `SITELINK` \| `CALLOUT` \| `STRUCTURED_SNIPPET`
  - `final_url` (string, required) — `SITELINK` only
  - `link_text` (string, required) — `SITELINK` only
  - `description_line_1` (string, required) — `SITELINK` only
  - `description_line_2` (string, optional) — `SITELINK` only
  - `start_date` (string, `YYYY-MM-DD`, optional) — `SITELINK` only
  - `end_date` (string, `YYYY-MM-DD`, optional) — `SITELINK` only
  - `text` (string, required) — `CALLOUT` only
  - `header` (string, required) — `STRUCTURED_SNIPPET` only
  - `values` (array of string, required) — `STRUCTURED_SNIPPET` only
- `guardrails`: same `max_assets_per_draft` cap as above

Sitelinks need both `start_date` and `end_date` to serve. Without a start
date the asset is created but never eligible.

### v5 Apply Types (Performance Max asset groups)

#### `UPDATE_ASSET_GROUP_ASSETS`
Adds, replaces or unlinks text assets in one Performance Max asset group.

A Performance Max campaign carries **asset groups**, not ad groups. The asset
group is what holds the final URL and the linked assets, so it is the PMax
equivalent of an ad group.

- `targets`:
  - `campaign_name` (string, required)
  - `asset_group_name` (string, required) — resolved by name inside the
    campaign, never by a raw id, so a typo cannot hit an unrelated asset group
  - `headlines` (array, optional): `{ "text": string }`
    - `text` ≤ 30 characters
  - `long_headlines` (array, optional): `{ "text": string }`
    - `text` ≤ 90 characters
  - `descriptions` (array, optional): `{ "text": string }`
    - `text` ≤ 90 characters
  - `remove_assets` (array, optional): `{ "text": string, "field_type": string }`
    - `field_type` ∈ `HEADLINE` \| `LONG_HEADLINE` \| `DESCRIPTION`
    - **Every entry names one exact live asset.** There is no auto-pick: the
      apply layer never decides on its own which asset to drop.
  - `replace` (boolean, default false)
    - `false` → merge with the assets already live (new assets only)
    - `true` → the lists in this action ARE the final list (other live assets
      are unlinked)
- `guardrails`:
  - `acknowledge_learning_period` (boolean, default false) — must be `true`
    when `remove_assets` is not empty
  - `max_assets_per_draft` (integer, default 10) — total asset count across
    the draft

**Why removals must be explicit.** Unlinking an asset destroys its
performance history, and the snapshot reversal only restores the *text*, not
the history. Picking the victim automatically would hide that decision inside
the tooling, so the draft has to name the asset and acknowledge the cost.

**Why the same text may not be removed and added at once.** The asset group's
text is immutable, so a "changed" asset is a new asset plus an unlink. A
draft that removes and re-adds the same text is contradictory and is rejected
(`remove_and_add_same_text`).

**How the write is executed.** One bulk `googleAds:mutate` request carries the
removals *and* the create+link of every new asset. The API does not resolve a
temporary resource name (`assets/-1`) across separate calls, and the slot
limit check has to see the removals to free the slots.

**How the limits are enforced.** The local slot count is **advisory only** —
the API's real ceiling for an asset group does not match the published caps
and differs between asset groups of the same type. The gate is the
`validateOnly` request the apply layer sends before every write: it fails
closed if the account rejects the change.

## Example (RSA Asset Refresh)

```json
{
  "draft_version": "0.4",
  "customer_id": "1234567890",
  "meta": {
    "budget_policy": {
      "allow_net_increase": false,
      "max_net_increase_pct": 10
    }
  },
  "actions": [
    {
      "id": "r1",
      "type": "UPDATE_RSA_ASSETS",
      "risk": "medium",
      "reason": "Headline from converting query 'crane rental'.",
      "targets": {
        "campaign_name": "High Intent - Search",
        "adgroup_name": "Crane Rental",
        "final_urls": ["https://example.com/rental"],
        "headlines": [
          { "text": "Crane Rental Service", "pinned_field": "HEADLINE_1" },
          { "text": "Certified Crane Operators" }
        ],
        "descriptions": [
          { "text": "Certified operators available 24/7 for your lift." }
        ],
        "replace": false
      },
      "guardrails": {
        "max_assets_per_draft": 10,
        "acknowledge_learning_period": false,
        "require_explicit_ad_group": true
      }
    },
    {
      "id": "s1",
      "type": "CREATE_ADGROUP_ASSET",
      "risk": "low",
      "reason": "Sitelink for fleet specs page.",
      "targets": {
        "campaign_name": "High Intent - Search",
        "adgroup_name": "Crane Rental",
        "asset_type": "SITELINK",
        "link_text": "Fleet Specs",
        "description_line_1": "See crane specs and capacity",
        "description_line_2": "Compare before you book",
        "final_url": "https://example.com/specs",
        "start_date": "2026-11-10",
        "end_date": "2026-12-10"
      }
    }
  ]
}
```

## Example (Performance Max Asset Group Fill)

```json
{
  "draft_version": "0.4",
  "customer_id": "1234567890",
  "meta": {
    "budget_policy": {
      "allow_net_increase": false,
      "max_net_increase_pct": 10
    }
  },
  "actions": [
    {
      "id": "ag-headlines",
      "type": "UPDATE_ASSET_GROUP_ASSETS",
      "risk": "medium",
      "reason": "Fill 7 empty headline slots with catalogue coverage.",
      "targets": {
        "campaign_name": "tes 2",
        "asset_group_name": "at home daycare feb",
        "headlines": [
          { "text": "Daily Drop-off Bayi & Toddler" },
          { "text": "After School Daycare" }
        ],
        "long_headlines": [
          { "text": "Kurikulum Kisah Tumbuh + CCTV" }
        ],
        "descriptions": [],
        "remove_assets": [],
        "replace": false
      },
      "guardrails": {
        "acknowledge_learning_period": true,
        "max_assets_per_draft": 20
      }
    }
  ]
}
```

## Example (Budget Reallocation)

```json
{
  "draft_version": "0.4",
  "customer_id": "1234567890",
  "meta": {
    "budget_policy": {
      "allow_net_increase": false,
      "max_net_increase_pct": 10
    }
  },
  "actions": [
    {
      "id": "b1",
      "type": "SET_CAMPAIGN_DAILY_BUDGET",
      "risk": "medium",
      "reason": "Budget-limited buyer intent campaign; scale cautiously within cap.",
      "targets": {
        "campaign_name": "High Intent - Search",
        "proposed_daily_budget_micros": 75000000
      },
      "guardrails": {
        "max_pct_change": 30,
        "cooldown_days": 7,
        "require_budget_neutral": true,
        "tracking_min_confidence": "medium"
      }
    }
  ]
}
```

Budget drafts MUST use the Apply Manifest. Legacy markdown parsing remains available for v1 negative and pause drafts only.
