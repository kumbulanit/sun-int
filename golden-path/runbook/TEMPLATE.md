# Runbook: <one failure> (<service>)

**One failure, one page.** If it doesn't fit, it covers more than one failure: split it. A new service starts with a filled-in example, `services/<service>/runbooks/slo-burn.md`: rewrite it for your service. For another failure, copy this template to `services/<service>/runbooks/<failure>.md` and point the alerts' `runbook` (in `charts/<service>/slo.yaml`) at it.

| | |
|---|---|
| **Service / team** | |
| **Alerts that link here** | e.g. `SLOFastBurn` (page), `DependencyFailing` (ticket) |
| **Where to look** | Prometheus queries, the Jaeger service, `kubectl -n <namespace> logs deploy/<service>` |
| **Escalate to** | the team that owns the failing thing, and how to reach them |

## What it means
The alert in plain words, not PromQL: what is failing, and since roughly when.

## User impact
In customer words. What it costs in error budget: `golden-path/tools/slo_math.py --bad-ratio <share failing> --spike-minutes <minutes so far>`.

## Check (first 5 minutes)
1. **Is it this failure?** One check. If not, say where to go instead: a page can have many causes.
2. 2–4 more checks, each **one command or link**, with what "bad" looks like.

## Mitigate (stop the harm, no code change)
1. Action → **worked if:** the signal that shows it.
2. Next action, in order.

## Fix (the cause)
Who has to find what, and our follow-ups.

## Don't
The common wrong moves for this failure, and why they make it worse.

## Afterwards
An incident review if it spent more than 20% of the budget (golden-path/README.md, "When your error budget runs out"). Update this page with what you learned.
