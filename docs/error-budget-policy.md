# Error budget policy: order validation

**Status:** our assumption until the Storefront team agrees it (question 1 in [questions-and-assumptions.md](questions-and-assumptions.md)).
**Owner:** Storefront product owner and the Storefront tech lead. The platform team owns how it's enforced, not the decisions.

## The budget

- **SLO:** 99.95% of validations are good (no 5xx error, answered in 250 ms or less), over a rolling 28 days.
- **Budget:** 0.05% of validations can be bad, about **49,700 requests per 28 days**.
- That's about 20 minutes of full outage on a normal day, but only **83 seconds** during the flash sale ([budget-math.md](budget-math.md)).

## What we do at each level

| Budget left (28 days) | What happens |
|---|---|
| **More than 25%** | Ship normally. Every deploy still goes through the canary. |
| **25% or less** | Keep shipping, but the next sprint starts with the top item from the last incident review. Risky changes (schema, dependency upgrades, config for pricing or the database) need a second reviewer. |
| **Exhausted (0% or less)** | **Freeze.** Only reliability fixes and rollbacks ship. The pipeline gate blocks everything else. The team writes an incident review within 5 working days. |

**Any single incident that spends more than 20% of the budget** gets an incident review, whatever is left.

## Lifting a freeze

The freeze ends when the budget is above 0% again. Because the window rolls, that can take weeks after a big incident. If recovery is more than 14 days away, the product owner and tech lead can lift the freeze early once the cause is fixed, the fix is verified (in production or under load test), and it's written down in the incident review.

## Exceptions

The product owner can approve one change during a freeze (for example a legal or security change). The pipeline run is labelled `budget-exception` with a link to the approval, and the exception is listed in the next incident review.

## When it's not our fault

The budget measures what customers get, whoever caused the problem. If a dependency (for example pricing) burns our budget:

- The freeze still applies, but the work it protects is **resilience to that dependency** (timeouts, cache, fallback), not waiting for the other team.
- We raise a ticket with the dependency's team, with the numbers.

## The flash sale

Whatever the budget, there's a deploy freeze **Saturday 13:00–17:00** (store local time), and capacity is scaled out on a schedule from 14:30 to 15:45. A load test at 1.5× peak runs in the week before each sale.

## How it's enforced

The pipeline's policy gate reads the budget left for this service from Prometheus before every production deploy:

- Budget above 0 → pass.
- Budget exhausted → fail, unless the run is labelled `reliability-fix`, `rollback` or `budget-exception`.
- Saturday 13:00–17:00 → fail, unless labelled `rollback`.

The budget left is `slo:error_budget_remaining{service="..."}`, generated from the service's `slo.yaml`. **If it can't be read, the gate stops** (D31): an unreadable budget must never wave a deploy through. A new service's first deploy, which has no history yet, runs with the label `first-deploy`.

## Review

The Storefront team and the platform team review this policy each quarter, or after any freeze.
