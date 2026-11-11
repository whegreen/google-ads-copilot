# Draft: PMax Asset Group Removal — 2026-11-11

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
      "id": "agr1",
      "type": "UPDATE_ASSET_GROUP_ASSETS",
      "risk": "high",
      "reason": "Unlink the two headlines that are off-intent for this campaign.",
      "targets": {
        "campaign_name": "tes 2",
        "asset_group_name": "at home daycare feb",
        "headlines": [
          { "text": "On-Demand Babysitter" }
        ],
        "long_headlines": [],
        "descriptions": [],
        "remove_assets": [
          { "text": "Child Day Care", "field_type": "HEADLINE" },
          { "text": "Home Day Care", "field_type": "HEADLINE" }
        ],
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
