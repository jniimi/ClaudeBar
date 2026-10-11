---
description: Cloudflare AI's JSON definition — the account lookup, one GraphQL read for Workers AI neurons and tokens and AI Gateway tokens and spend, the plan from subscriptions, and how cloudflare-ai-usage.js prices the day-by-day neuron overage.
---

# Cloudflare AI as a definition

> Status: **built**. Field names were verified by introspection on 2026-10-11 (EdgeMeter's
> `scripts/introspect-datasets.sh`), and the query was run live: Gateway's `sum.cost` came back
> in dollars. Workers AI's numbers wait for an account with Workers AI traffic, and
> `workers_paid` for a Workers Paid account.

`cloudflare-ai.json` reads one Cloudflare account with a read-only API token. It needs no new
engine piece except one `SystemValues` row (below).

```text
CLOUDFLARE_API_TOKEN → pasted API token (Account Analytics: Read; Billing: Read optional)
        ▼
step accounts       GET  /client/v4/accounts                 keep accountId = $.result.0.id
step usage          POST /client/v4/graphql                  body: one query, three aliases
                      today  aiInferenceAdaptiveGroups  datetime ≥ {{system.day.iso8601}}   sum.totalNeurons
                      days   aiInferenceAdaptiveGroups  date ≥ {{system.month.date}}  by date, modelId
                             sum.totalNeurons · totalInputTokens · totalOutputTokens
                      gw     aiGatewayRequestsAdaptiveGroups  date ≥ {{system.month.date}}  by provider, model
                             sum.tokensIn · tokensOut · cost
step plan (optional) GET /client/v4/accounts/{{accountId}}/subscriptions
step bills (optional) GET /client/v4/accounts/{{accountId}}/billing/history?per_page=1   (newest first; amount_to_pay in dollars)
        ▼
cloudflare-ai-usage.js
```

## What the person sees

| Line | From | Rule |
|---|---|---|
| **Neurons today** — a quota, `4.2k / 10k neurons`, resets 00:00 UTC | `today` | 10k neurons a day on both plans; Free stops there, Paid charges past it |
| **This month · est.** — cost `apiCost`, one line per day-overage total | `days` + plan | Workers Paid: Σ per UTC day of max(0, neurons − 10k) × $0.011 per 1k. Free: no cost (it stops instead of charging). Plan unknown: no cost, a note says why |
| Note: **Workers AI tokens** — `1.2M in · 340k out this month`, top 3 models | `days` | tokens are context; Workers AI bills neurons, never tokens |
| Note: **AI Gateway** — `2.1M tokens · $3.40 at providers (est.)` | `gw` | Gateway's estimate of what the upstream providers charge; not on the Cloudflare bill, so never in the cost |
| Note: **Last invoice** — `$14.20 · Sep 21` | `bills` | only with Billing: Read |
| Plan badge: *Workers Paid* / *Free* | `plan` | `rate_plan.id == "workers_paid"` (unverified: no Paid account read yet); any other list → Free; step failed → no badge |

## Laws

- One account: the first the token can see. A token scoped to one account is the setup the README asks for; picking among several waits for a request.
- The month is the **calendar month in UTC** (`{{system.month.date}}`), not the subscription's period: a Free account has no Workers subscription to read a period from. The cost says *est.*.
- A GraphQL answer can be HTTP 200 with `errors`: the script maps an auth error to `sessionExpired` (asks for Account Analytics: Read) and any other to `parseFailed` with Cloudflare's message.
- A refused token answers **400** (code 9106), 401 or 403 → *Use a Cloudflare API token with Account Analytics: Read.*
- `plan` and `bills` accept 400/401/403 as answers: the engine treats a refused step as a refused key for every step, and a token without Billing: Read must still show usage. The script reads `success: false` as *no Billing: Read* and says so in the Bill note.
- Prices live in the script's one constant table, with the date checked against [Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/) (2026-10-11).

## The one engine change

`SystemValues` gains a row `month.<format>`: the first day of the current UTC month, like
`day.<format>` is today's UTC midnight. One row, a `SystemTemplateTests` case, ENGINE_DESIGN §2.9 updated.
