# Draft: RSA Asset Refresh — 2026-11-10
Status: proposed
Skill: /google-ads rsas
Account: Test Equipment Co. (1234567890)

## Summary
Refresh RSA assets in the Crane Rental ad group with buyer language from converting queries.

## Evidence
- Source: search-terms review
- Buyer language clusters: crane rental, certified operator

## Proposed Actions

### Ad Group: "Crane Rental" in Campaign "High Intent - Search"

#### New Headlines
| # | Headline (max 30 chars) | Pin Position |
|---|-------------------------|--------------|
| 1 | Certified Crane Operators | H1 |
| 2 | Crane Rental Service | None |

#### New Descriptions
| # | Description (max 90 chars) | Pin Position |
|---|---------------------------|--------------|
| 1 | Certified operators available 24/7 for your lift. | None |

## Apply Manifest

~~~json
{
  "draft_version": "0.3",
  "customer_id": "1234567890",
  "customer_name": "Test Equipment Co.",
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
          { "text": "Certified Crane Operators", "pinned_field": "HEADLINE_1" },
          { "text": "Crane Rental Service" }
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
~~~

## Risk
- New assets enter a learning period

## Reversibility
Assets restore from a snapshot; removed asset performance history does not come back.

## Confidence
High — copy comes from converting query language.

## Review
- [ ] Evidence checked
- [ ] Collateral risk checked
- [ ] Dependencies checked
- **Decision:** approve | defer | reject
- **Decision reason:** ____
- **Reviewed by:** ____
- **Reviewed on:** ____
