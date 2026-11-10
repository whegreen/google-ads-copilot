# Draft: Asset Update — [DATE]
Status: proposed
Skill: /google-ads rsas | /google-ads structure
Account: [Customer ID / Name]

## Summary
[One paragraph: which ad group, what assets change, driven by what.]

## Evidence
- Source: [RSA analysis / search-terms review]
- Buyer language clusters: [Key modifiers and phrases from converters]
- Current asset performance: [How many BEST/GOOD/LOW/UNRATED assets]
- Related workspace files: winners.md, queries.md, assets.md

## Proposed Actions

### Ad Group: "[Name]" in Campaign "[Name]"

#### New Headlines
| # | Headline (max 30 chars) | Pin Position | Source Language |
|---|-------------------------|-------------|----------------|
| 1 | [headline text] | [None / H1 / H2 / H3] | [query/modifier] |
| 2 | [headline text] | [None / H1 / H2 / H3] | [query/modifier] |
| 3 | [headline text] | [None] | [query/modifier] |

#### New Descriptions
| # | Description (max 90 chars) | Pin Position | Source Language |
|---|---------------------------|-------------|----------------|
| 1 | [description text] | [None / D1 / D2] | [query/modifier] |
| 2 | [description text] | [None] | [query/modifier] |

#### Assets to Consider Removing
| Asset | Current Label | Reason |
|-------|--------------|--------|
| [text] | [LOW] | [Poor CTR, off-message, etc.] |

> Only list removals in the Apply Manifest when you set `replace: true` and
> acknowledge the learning period. Removing an asset deletes its performance
> history — the undo restores the text, not the history.

## Apply Manifest

~~~json
{
  "draft_version": "0.3",
  "customer_id": "[10-digit customer id]",
  "customer_name": "[account name]",
  "actions": [
    {
      "id": "r1",
      "type": "UPDATE_RSA_ASSETS",
      "risk": "medium",
      "reason": "[one line: which buyer language drove this]",
      "targets": {
        "campaign_name": "[exact campaign name]",
        "adgroup_name": "[exact ad group name]",
        "final_urls": ["https://example.com/landing"],
        "headlines": [
          { "text": "[headline, max 30 chars]", "pinned_field": "HEADLINE_1" },
          { "text": "[headline, max 30 chars]" }
        ],
        "descriptions": [
          { "text": "[description, max 90 chars]" }
        ],
        "replace": false
      },
      "guardrails": {
        "max_assets_per_draft": 10,
        "acknowledge_learning_period": false,
        "require_explicit_ad_group": true
      }
    }
  ]
}
~~~

## Extension Assets (optional)

Add a `CREATE_ADGROUP_ASSET` action to the manifest above for each sitelink,
callout, or structured snippet:

```json
{
  "id": "s1",
  "type": "CREATE_ADGROUP_ASSET",
  "risk": "low",
  "reason": "[one line]",
  "targets": {
    "campaign_name": "[exact campaign name]",
    "adgroup_name": "[exact ad group name]",
    "asset_type": "SITELINK",
    "link_text": "[max 25 chars]",
    "description_line_1": "[max 35 chars]",
    "description_line_2": "[max 35 chars, optional]",
    "final_url": "https://example.com/page",
    "start_date": "2026-01-01",
    "end_date": "2026-12-31"
  }
}
```

Other asset types:
- `CALLOUT` → `asset_type: "CALLOUT"` + `text`
- `STRUCTURED_SNIPPET` → `asset_type: "STRUCTURED_SNIPPET"` + `header` + `values` (array)

## Risk
- New assets enter a learning period (typically 1-2 weeks)
- Pinning can reduce combinations — use sparingly
- Removing assets with impressions may temporarily affect ad strength

## Reversibility
Moderate — assets restore from a snapshot. Removed assets lose their
performance history and it cannot be recovered.

## Dependencies
- [e.g., "Matches the intent segmentation from structure draft X"]

## Confidence
[High / Medium / Low] — [reasoning]

## Review
- [ ] Evidence checked
- [ ] Collateral risk checked
- [ ] Dependencies checked
- [ ] Ad group named exactly as it appears in the account
- **Decision:** approve | defer | reject
- **Decision reason:** ____
- **Reviewed by:** ____
- **Reviewed on:** ____
- **Applied on:** ____
- **Notes:** ____
