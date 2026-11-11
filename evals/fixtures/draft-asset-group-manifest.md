# Draft: PMax Asset Group Headline Fill — 2026-11-11

Status: proposed
Account: Crane Rental Co. (1234567890)

## Apply Manifest

~~~json
{
  "draft_version": "0.4",
  "customer_id": "1234567890",
  "customer_name": "Crane Rental Co.",
  "meta": {
    "budget_policy": {
      "allow_net_increase": false,
      "max_net_increase_pct": 10
    }
  },
  "actions": [
    {
      "id": "ag1",
      "type": "UPDATE_ASSET_GROUP_ASSETS",
      "risk": "medium",
      "reason": "Fill empty Performance Max headline slots with on-demand copy.",
      "targets": {
        "campaign_name": "tes 2",
        "asset_group_name": "at home daycare feb",
        "headlines": [
          { "text": "On-Demand Babysitter" },
          { "text": "Trusted Sitter at Home" }
        ],
        "long_headlines": [
          { "text": "Book a trusted on-demand sitter for your child today" }
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
~~~
