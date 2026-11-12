# Google Ads Copilot

> **Public Alpha — Builder Preview**
> I built an OpenClaw agent that manages Google Ads accounts through intent analysis instead of bid automation. All three layers — Read → Draft → Apply — are live and tested on real accounts. This is an early release for builders and agencies who want to try the intent-first approach.

Most Google Ads problems are not bid problems.
They are **intent-mixing problems**.

Your account is buying different kinds of searches — buyers, comparison shoppers, researchers, job seekers, freebie hunters — and mixing them together. When that happens, bids optimize against noise, RSAs get generic, good traffic subsidizes bad traffic, and every budget decision is distorted.

Google Ads Copilot is an AI agent that reads search behavior, builds a durable Intent Map, finds waste, isolates signal, and turns what the account is learning into structure, copy, and scale decisions. Every recommendation is staged as a reviewable draft. Nothing changes without your approval.

Not a dashboard. Not a bid optimizer. Not a generic audit checklist.

**A strategist with memory.**

---

## How It Works

```
READ  →  DRAFT  →  APPLY
```

| Layer | What happens |
|-------|-------------|
| **Read** | Pull live account data via Google's official `google-ads-mcp` MCP server (read-only). Or work with manual CSV exports — same analytical engine either way. |
| **Draft** | Every actionable finding becomes a concrete proposal — specific negatives, structure changes, budget moves, RSA directions — staged for human review. |
| **Apply** | Controlled write-back for approved drafts. Live scope: **add negative keywords**, **pause keywords/ad groups**, and **campaign daily budget changes** via manifest-backed guardrails. Dry run, explicit confirmation, per-action verification, full audit trail, instant undo. |

**See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design, safety model, and roadmap.**

---

## Two Ways to Run It

### Connected Mode (recommended)
Hook up the MCP server with OAuth + developer token and the agent pulls live data automatically — search terms, keywords, conversions, budgets, everything via GAQL.

You get: live account data, automatic account discovery, date-range fallback for sparse accounts, cross-referencing search terms against targeted keywords, and health detection out of the box.

**Setup:** `./install.sh auto` → `/google-ads connect setup` → you're live. See `data/mcp-config.md` for details. If your host uses a non-default skills path, override it with `CLAUDE_TARGET=...` or `OPENCLAW_TARGET=...`.

### Export Mode (zero setup)
Paste a CSV from Google Ads. The analytical engine is the same — you just feed it manually. Good for one-off audits or accounts where you don't have API access yet.

Both modes produce the same quality of analysis and drafts.

---

## What It Can Do

15 skills across three layers. The full operator workflow is in [OPERATOR-PLAYBOOK.md](OPERATOR-PLAYBOOK.md).

### Run the Account
| Command | What happens |
|---------|-------------|
| `/google-ads connect` | Set up, health check, pick an account |
| `/google-ads daily` | What matters today — bleeding campaigns, waste, opportunities |
| `/google-ads audit` | Full strategic review across all layers |
| `/google-ads draft-summary` | See what's queued, prioritized, with dependencies mapped |

### Analyze
| Command | What happens |
|---------|-------------|
| `/google-ads search-terms` | Find waste, signal, messaging clues, routing problems. For PMax-heavy accounts, falls back to query-row visibility mode when classic Search-term rows are unavailable |
| `/google-ads intent-map` | Build the account's durable intent model |
| `/google-ads negatives` | Specific negatives with scope, risk, and collateral notes |
| `/google-ads tracking` | Is the account trustworthy enough to optimize? |
| `/google-ads structure` | Campaign/ad group restructuring recommendations |
| `/google-ads rsas` | RSA directions from actual buyer language |
| `/google-ads budget` | Budget/scaling decisions grounded in signal quality |
| `/google-ads plan` | Plan or rebuild account architecture from scratch |
| `/google-ads pmax` | PMax analysis through the intent contamination lens |
| `/google-ads landing-review` | Landing page diagnosis — tracking vs UX vs both |

### Act
| Command | What happens |
|---------|-------------|
| `/google-ads apply [draft]` | Execute an approved draft — dry run, confirm, verify, log |
| `/google-ads undo [rev-id]` | Reverse any applied action instantly |
| `/google-ads apply log` | Full audit trail of everything applied |

---

## Why This Exists

Most Google Ads tools report metrics, enforce generic best practices, or automate bids. None of them think about what the account is *actually buying*.

Google Ads Copilot starts from search intent — what people typed, what they meant, and whether the account structure reflects that reality.

| | What it means |
|---|---|
| **Intent-first** | Reads search behavior, not just metrics |
| **Memory** | Compounds learning across sessions — never starts from scratch |
| **Decision-oriented** | Every output ends in "what to do," not "what happened" |
| **Draft-staged** | Concrete proposals you can read, approve, or reject |
| **Human-in-the-loop** | Nothing changes without your explicit confirmation |
| **Safe writes** | Smallest blast radius first, full audit trail, instant undo |
| **Works anywhere** | Live API or manual exports — same engine |

---

## Getting Started

### Try It in 5 Minutes (export mode)
1. `./install.sh auto`
2. Export search terms from Google Ads (last 30 days, CSV)
3. `/google-ads search-terms` → paste your data
4. Check `workspace/ads/drafts/` for what it found

### Full Setup (connected mode)
1. Configure the MCP server: [data/mcp-config.md](data/mcp-config.md)
2. `./install.sh auto`
3. Create local credential/env files from the committed templates:
   `cp data/google-ads-adc-authorized-user.template.json data/google-ads-adc-authorized-user.json`
   `cp data/google-ads-mcp.test.env.example.sh data/google-ads-mcp.test.env.sh`
4. Fill in your real values, then `source data/google-ads-mcp.test.env.sh`
5. `./scripts/test-mcp.sh` to verify connectivity
6. `/google-ads connect setup` → discovers your accounts, picks one, writes workspace
7. `/google-ads daily` or `/google-ads audit` → live data flows automatically
8. For PMax-heavy accounts, use `./scripts/test-search-terms.sh <customer-id>` to verify query visibility and fallback behavior
9. Review drafts → approve → apply → verify

The repo does not ship any real credentials or live test files. Only templates are committed.

### Helper scripts

Two families, no overlap:

| Script | Needs |
|---|---|
| `scripts/verify-wa-click.py` | nothing — v25 REST API via urllib |
| `scripts/verify-asset-group-assets.py` | nothing |
| `scripts/asset-group-inventory.py` | nothing |
| `scripts/verify-asset-performance.py` | nothing — per-asset PMax performance + the F2 scorecard |
| `scripts/check-gtm-tags.py` | nothing — checks whether the GTM container publishes the conversion tags |
| `scripts/verify-deploy-tracking.sh` | nothing — post-deploy gate for snippet + dataLayer |
| `scripts/measurement-status.sh` | nothing — one command for the whole measurement period |
| `scripts/check-gtm-scope.py` | nothing — which OAuth scopes a client advertises |
| `scripts/gtm-publish.py` | a refresh token with the GTM scopes — see [requirements-dev.txt](requirements-dev.txt) |
| `scripts/pmax_analysis.py`, `tracking_check.py`, `campaign_summary.py`, `landing_urls*.py`, `list_customers_direct.py` | the Google Ads client library — see [requirements-dev.txt](requirements-dev.txt) |

The client-library family needs Python 3.11–3.13 (protobuf's upb extension does not build on 3.14+):

```bash
python3.11 -m venv .venv-gads
.venv-gads/bin/pip install -r requirements-dev.txt
.venv-gads/bin/python scripts/pmax_analysis.py
```

### Publishing the GTM conversion tags

The GTM tags are the only part of the conversion path that is not code. They
need OAuth scopes the Tag Manager API checks separately from the Ads API, and
the scope names are the modern per-resource ones:

| Scope | Grants |
|---|---|
| `tagmanager.manage.accounts` | `accounts.list`, `accounts.get` |
| `tagmanager.readonly` | read containers |
| `tagmanager.edit.containers` | create tags and triggers |
| `tagmanager.edit.containerversions` | create a container version |
| `tagmanager.publish` | publish it |

Only scopes the OAuth client advertises may be requested — one unknown scope
invalidates the whole authorization request, and an existing refresh token
never gains a scope on its own. Check what the client accepts first:

```bash
python3 scripts/check-gtm-scope.py --all     # no login needed
python3 scripts/oauth-login.py               # fresh consent
python3 scripts/gtm-publish.py --use-adc     # dry run: creates, previews, stops
python3 scripts/gtm-publish.py --use-adc --publish
python3 scripts/check-gtm-tags.py            # marker check on the published container
```

### Install from a Release Bundle
You can install from the repo as usual, or from a packaged bundle:

```bash
./install.sh auto
./install.sh /path/to/google-ads-copilot-0.2.0.tar.gz auto
./install.sh /path/to/google-ads-copilot-0.2.0 openclaw
```

Release bundles are built with `./scripts/package/build-release.sh <version>`.

**See [DEMO-WORKFLOW.md](DEMO-WORKFLOW.md) for a guided walkthrough of the full cycle.**

### Contributing

This repo keeps a MegaMemory knowledge graph at `.megamemory/knowledge.db`
(tracked in git, so the graph syncs across machines) and wires the sync through
git hooks. Enable them once after cloning:

```bash
git config core.hooksPath .githooks
```

The `pre-push` hook checkpoints the graph, refuses to push while it still holds
unresolved conflicts, and blocks the push if the graph contains credential or
real-client patterns (this repo is public — see
[PUBLISH-CHECKLIST.md](PUBLISH-CHECKLIST.md)). It needs Node 22+ (`node:sqlite`).

Developers use `/develop-command` (or `/develop-plan` → `/develop-code`) for the
structured refactor workflow: plan and lock scope first, then implement.

**Environment variables:**
| Variable | Required | Notes |
|----------|----------|-------|
| `GOOGLE_APPLICATION_CREDENTIALS` | Yes | Path to OAuth/ADC credentials JSON |
| `GOOGLE_CLOUD_PROJECT` | Yes | Google Cloud project ID |
| `GOOGLE_ADS_DEVELOPER_TOKEN` | No | Legacy only — developer tokens were sunset 2026-09-09. Access is bound to the Cloud project that owns the OAuth credentials |
| `GOOGLE_ADS_LOGIN_CUSTOMER_ID` | If MCC | Manager account ID (no dashes) |

---

## Workspace Memory

Every session compounds. The agent writes to `workspace/ads/` — a persistent knowledge base that survives between runs:

| File | Purpose |
|------|---------|
| `account.md` | Account profile and setup |
| `goals.md` | Business objectives and KPIs |
| `intent-map.md` | Durable model of search behavior |
| `queries.md` | Query patterns and clusters |
| `negatives.md` | Exclusion history |
| `winners.md` | What's working and why |
| `tests.md` | Active tests and hypotheses |
| `findings.md` | Analytical notes |
| `change-log.md` | What was changed and when |
| `learnings.md` | What the account has taught us |
| `drafts/` | Staged action proposals |
| `audit-trail/` | Apply session logs + reversal registry |

Draft filenames use `YYYY-MM-DD-[account-slug]-[type].md`. Multi-draft audit runs also produce `_batch-YYYY-MM-DD-[account-slug].md` as a durable audit packet, while `_summary.md` remains the live prioritized backlog snapshot.

---

## Package Structure

```text
google-ads-copilot/
├── README.md                    # This file
├── ARCHITECTURE.md              # Three-layer design doc
├── APPLY-LAYER.md               # Apply layer design (safety, reversibility, audit)
├── OPERATOR-PLAYBOOK.md         # Full operator workflow loop
├── CHANGELOG.md                 # Release history
├── LICENSE
├── install.sh
│
├── google-ads/                  # Orchestrator skill
│   ├── SKILL.md
│   └── references/              # Strategic playbooks
│
├── scripts/                     # Helper scripts + apply layer CLI
│   ├── apply-layer/             # Write-path CLI (bash + curl + jq)
│   └── list-customers.sh        # Account discovery
│
├── skills/                      # Analytical skills (15 skills)
│   ├── google-ads-apply/
│   ├── google-ads-audit/
│   ├── google-ads-budget/
│   ├── google-ads-connect/
│   ├── google-ads-daily/
│   ├── google-ads-draft-summary/
│   ├── google-ads-intent-map/
│   ├── google-ads-landing-review/
│   ├── google-ads-negatives/
│   ├── google-ads-plan/
│   ├── google-ads-pmax/
│   ├── google-ads-rsas/
│   ├── google-ads-search-terms/
│   ├── google-ads-structure/
│   └── google-ads-tracking/
│
├── data/                        # Data layer (MCP config, GAQL recipes)
├── drafts/                      # Draft templates per action type
├── examples/                    # Sanitized example outputs
├── evals/                       # Eval suite
└── workspace-template/          # Blank workspace for new accounts
```

---

## Apply Scope

| Action | Status | Risk | Undo |
|--------|--------|------|------|
| Add campaign-level negative keyword | ✅ Live | Low | Remove the negative |
| Add ad-group-level negative keyword | ✅ Ready | Low | Remove the negative |
| Pause keyword | ✅ Ready | Low | Re-enable keyword |
| Pause ad group | ✅ Ready | Medium | Re-enable ad group |
| Set campaign daily budget | ✅ Live (manifest-backed) | Medium | Restore the prior `amount_micros` |

Budget applies are limited to campaign daily budgets and require an `## Apply Manifest` JSON block plus hard guardrails: max 30% per action, min meaningful delta, 7-day cooldown, tracking confidence gate, pending-tracking-draft block, budget-neutral default, and `confirm budgets` confirmation.

**Still excluded:** shared budgets, bid strategy changes, campaign creation, RSA edits, enabling paused entities, deletions.

---

## What's Next

This is a public alpha. The analytical engine and apply layer are solid — tested on real accounts with real money. Current next steps:

- Expanded write actions after budget apply proves out
- More example walkthroughs from real (anonymized) accounts
- Broader eval coverage for decision quality and write-path regressions
- Packaging and release automation for broader distribution

If you're running Google Ads for clients or your own business, try it. Break it. Tell me what's missing.

---

## License

See [LICENSE](LICENSE).
