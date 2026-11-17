# Questions for the Storefront team, and our assumptions

The ticket doesn't tell us everything. These are the questions we'd ask the Storefront team. Until they answer, we build on the assumption next to each one. If an answer changes an assumption, we update this file and [DECISIONS.md](../DECISIONS.md).

Status: **sent, no answers yet** (draft email at the bottom).

| # | Question | Why it matters | Our assumption until answered |
|---|---|---|---|
| 1 | **What should happen when the error budget runs out?** | Without an agreed policy the SLO is just a number on a dashboard. | Only reliability fixes and rollbacks ship until the budget recovers. The pipeline gate enforces it, and the product owner can sign an exception. Details: [error-budget-policy.md](error-budget-policy.md). |
| 2 | **What counts as a failed validation?** Is "out of stock" or "price changed" a failure? Where is the 250 ms measured? | Decides what the SLI counts. Counting correct "no" answers as failures would make the SLO meaningless. | A correct "no" (unknown item, out of stock, over the limit, price changed) is a **good** event. Malformed requests (400) don't count against us. Only 5xx and responses slower than 250 ms are bad. The 250 ms is measured at our service; the load test measures from the client as a cross-check. |
| 3 | **When pricing is slow, may we check against a recently cached price?** How old can it be? Prices change at 15:00 when the sale starts. | This is our main defence against a slow pricing service. Too short a cache helps nobody; too long a cache shows wrong prices. | Yes, up to **60 s old**, and the response says `"price_source": "cache"`. Checkout re-prices the order, so a customer is never charged a cached price. Known edge case: in the first minute of the sale, a cart with the new sale price may get PRICE_CHANGED against the cached pre-sale price. |
| 4 | **Can we freeze deploys and add capacity ahead of the Saturday sale?** Which timezone is "Saturday 15:00"? | At 600 req/s a full outage spends the whole month's budget in 83 s ([budget-math.md](budget-math.md)). Alerts can't save the sale; preparation can. | Deploy freeze Saturday 13:00–17:00. Scale out on a schedule from 14:30 to 15:45. Load test at 1.5× the peak (900 req/s) in the week before. Times are store local time, held in one config value. |
| 5 | **Who is on call, and when should we wake someone up?** | You build it, you run it: the product team gets the pages, so they should agree what pages. | The Storefront on-call gets **pages** 24/7 (fast and slow SLO burn). **Tickets** (slow burn, pricing dependency degraded) go to the team's queue for working hours. The platform team supports the kit, not the service. |
| 6 | **How do callers (web, app, checkout) retry when we fail or are slow?** What's their timeout? | At 600 req/s an instant retry on every failure doubles the load at the worst moment (a retry storm). | Callers retry **once**, with jitter, honour `Retry-After` on 503, and time out after 1 s. We'll check this with the client teams before the sale. |
| 7 | **Where do order limits come from, and who changes them?** | Decides the data model and whether limits need a deploy to change. | Limits live in Postgres, owned by merchandising: max 20 lines per order, default max 10 per line, with per-SKU overrides (e.g. 2 per customer on flash-sale items). Changing a limit is a data change, not a deploy. |
| 8 | **Does checkout check stock and price again when the order is placed?** | Decides whether validation must reserve stock or be exact. | Yes. Validation is **advisory** and reserves nothing; checkout is the source of truth. Stock can change between validating and placing an order. |
| 9 | **What's the pricing service's normal latency and SLO? How are its credentials rotated?** | Our 150 ms timeout only works if pricing is normally much faster. If its p99 is normally 120 ms we'd fall back all the time. | Pricing p99 is under 50 ms normally. Credentials come from a secret store and are rotated with an overlap, so a 401 means something is broken (alert), not routine. |
| 10 | **One currency? How big is the catalogue, and how many items does a typical order have?** | Sizes the cache, the database query and the load-test payloads. | One currency, prices as integers in minor units (cents). Thousands of SKUs, not millions. A typical order has 1–5 lines. |
| 11 | **What should happen if the same product appears twice in one order?** | Decides whether the API merges lines or refuses them. | Refused as malformed (400), so the rules see one line per product. Clients merge lines before sending. |

---

## Draft reply to the brief

> **Subject:** Re: Order validation API: a few questions before the sales weekend
>
> Hi Storefront team,
>
> We've picked up the order validation ticket and are building it on the new golden path, so you'll get the SLO, alerts, dashboards, pipeline and runbook with it. Before we lock things in, we have a few questions. Where we don't hear back, we'll go with the assumption in brackets, and you can change any of them later.
>
> 1. **When the error budget runs out, what should happen?** (Only fixes and rollbacks ship until it recovers; your product owner can approve exceptions.)
> 2. **Is "out of stock" or "price changed" a failure?** (No: a correct "no" is a good answer. Only errors and responses slower than 250 ms count against the budget.)
> 3. **If pricing is slow, may we check against a price cached for up to 60 seconds?** Checkout would still re-price the order. (Yes, 60 s.)
> 4. **Can we freeze deploys on Saturday 13:00–17:00 and add capacity from 14:30?** Which timezone is the 15:00 sale in? (Yes; store local time.)
> 5. **Who is on call, and should we wake them at night?** (Your on-call gets paged 24/7 only when the budget burns fast; everything else becomes a ticket.)
> 6. **How do your apps retry when we fail?** (Once, with jitter, respecting Retry-After, with a 1 s timeout.)
> 7. **Who owns the order limits?** (Merchandising, stored in the database: 20 lines per order, 10 per line by default, per-item overrides.)
> 8. **Does checkout check stock and price again?** (Yes; validation doesn't reserve stock.)
> 9. **What's the pricing service's normal speed, and how are its credentials rotated?** (p99 under 50 ms; rotated with an overlap.)
> 10. **One currency, and roughly how many products?** (One currency; thousands of products.)
>
> One number to flag: the budget allows about 20 minutes of full outage a month on a normal day, but **during the flash sale the whole month's budget lasts about 80 seconds**. That's why we're asking about the freeze and the pre-scaling. They protect the sale better than any alert can.
>
> Thanks,
> [Your name]
