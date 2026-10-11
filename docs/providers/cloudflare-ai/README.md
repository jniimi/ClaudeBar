---
description: Track a Cloudflare account's Workers AI neurons against 10k a day, Workers AI and AI Gateway tokens, the Workers Paid overage and the last invoice, with a read-only API token. Use when setting up Cloudflare AI.
---

# Cloudflare AI

Shows one Cloudflare account's AI usage:

- **Workers AI neurons**: today's neurons against the free 10k a day, resetting at 00:00 UTC. Free stops at 10k; Workers Paid charges past it.
- **This month · est.**: on Workers Paid, each day's neurons past 10k at $0.011 per 1k, added up for the calendar month (UTC). On Free there's no cost.
- **Workers AI tokens**: tokens in and out this month, with the busiest models. Workers AI bills neurons, so tokens are for context.
- **AI Gateway**: tokens through your gateways this month, and Gateway's estimate of what the upstream providers (OpenAI, Google AI Studio, …) charge. That money is billed by those providers, not Cloudflare, so it's never in the cost.
- **Last invoice**: the newest invoice's amount and date.

## Setup

1. [Create an API token](https://dash.cloudflare.com/profile/api-tokens) with **Account Analytics: Read**. Add **Billing: Read** for the plan, the overage estimate and invoices.
2. Settings → Providers → Cloudflare AI: turn it on. It's **off by default**.
3. Paste the token into **API TOKEN**, then **Save & Test Connection**. Or set `CLOUDFLARE_API_TOKEN` in ClaudeBar's environment.

## Multiple accounts

**Add Account** takes another token; each added account uses only its own token. A token reads the first Cloudflare account it can see, so scope each token to one account.

## Gotchas

- **"Use a Cloudflare API token with Account Analytics: Read."** Cloudflare refused the token, or the token can't read the account's analytics.
- **"Give the token Billing: Read to see the plan, the overage and invoices"**: the usage still shows; only the plan, the cost and invoices need Billing: Read.
- **The month is the calendar month in UTC**, not your subscription's billing period, so the estimate can differ from the invoice by a few days' usage.
- **AI Gateway's spend is an estimate** from Cloudflare's own price list for each provider; check the provider's bill for the real figure.

## See also

[troubleshooting](../../troubleshooting.md) · [design](design.md)
