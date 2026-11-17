#!/usr/bin/env python3
"""SLO math: error budget, burn-rate alerts, detection times, incident cost, Little's law.

Every SLO number in docs, alerts and runbooks should come from this script.
Defaults are the order validation service, so with no options it prints
that service's numbers.

Examples:
  slo_math.py
  slo_math.py --objective 99.9 --window-days 30 --steady-rps 5 --peak-rps 0
  slo_math.py --bad-ratio 0.2 --spike-minutes 5
"""
import argparse

# Google SRE Workbook alert set: (name, severity, share of budget spent, long window h, short window h)
ALERTS = [
    ("fast burn", "page", 0.02, 1, 5 / 60),
    ("slow burn", "page", 0.05, 6, 0.5),
    ("budget leak", "ticket", 0.10, 72, 6),
]


def hours(h):
    """Format a window length the way Prometheus writes it."""
    if h < 1:
        return f"{h * 60:g}m"
    if h >= 24 and h % 24 == 0:
        return f"{h / 24:g}d"
    return f"{h:g}h"


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--objective", type=float, default=99.95, help="SLO target in percent (default 99.95)")
    p.add_argument("--window-days", type=int, default=28, help="rolling SLO window in days (default 28)")
    p.add_argument("--steady-rps", type=float, default=40, help="normal traffic in req/s (default 40)")
    p.add_argument("--peak-rps", type=float, default=600, help="peak traffic in req/s, 0 for no peak (default 600)")
    p.add_argument("--peak-minutes", type=float, default=20, help="how long each peak lasts (default 20)")
    p.add_argument("--peaks-per-window", type=int, default=4, help="peaks in one window (default 4)")
    p.add_argument("--bad-ratio", type=float, action="append",
                   help="share of requests bad during an incident, e.g. 0.2; repeat for several "
                        "(default 1.0, 0.2, 0.1, 0.015)")
    p.add_argument("--spike-minutes", type=float, default=5, help="incident length for the cost table (default 5)")
    p.add_argument("--timeout-ms", type=float, default=150, help="dependency timeout (default 150)")
    p.add_argument("--worst-slow-s", type=float, default=3.0,
                   help="dependency call time when every call is slow (default 3.0)")
    p.add_argument("--slow-share", type=float, default=0.2, help="share of dependency calls that are slow (default 0.2)")
    p.add_argument("--slow-avg-s", type=float, default=3.5, help="average time of a slow call (default 3.5)")
    p.add_argument("--fast-ms", type=float, default=20, help="normal request time (default 20)")
    a = p.parse_args()

    bad_ratios = a.bad_ratio or [1.0, 0.2, 0.1, 0.015]
    budget = round(1 - a.objective / 100, 10)
    window_h = a.window_days * 24
    window_s = window_h * 3600
    has_peak = a.peak_rps > a.steady_rps and a.peak_minutes > 0 and a.peaks_per_window > 0

    print("== Error budget")
    print(f"objective {a.objective}% over {a.window_days} d -> budget {budget:.4%} (1 bad request in {1 / budget:,.0f})")
    print(f"window: {window_h:,} h = {window_h * 60:,} min")
    print(f"full outage allowed (time view, constant traffic): {window_h * 60 * budget:.1f} min")

    steady = a.steady_rps * window_s
    extra = a.peaks_per_window * a.peak_minutes * 60 * (a.peak_rps - a.steady_rps) if has_peak else 0
    total = steady + extra
    allowed = total * budget
    print(f"requests per window: steady {steady:,.0f} + peak extra {extra:,.0f} = {total:,.0f}")
    print(f"bad requests allowed per window: {allowed:,.0f}")
    if has_peak:
        one_peak = a.peak_rps * a.peak_minutes * 60
        print(f"one peak: {one_peak:,.0f} requests")
        print(f"share of one peak that can fail before the whole budget is gone: {allowed / one_peak:.1%}")
        print(f"full outage for a whole peak = {one_peak / allowed:.1f}x the budget")
        print(f"full outage at {a.peak_rps:g} req/s spends the whole budget in {allowed / a.peak_rps:,.0f} s")
    print(f"full outage at {a.steady_rps:g} req/s spends the whole budget in {allowed / a.steady_rps / 60:,.1f} min")

    print(f"\n== Burn-rate alerts ({a.window_days}-day window)")
    print("burn = share of budget spent x window hours / long window hours")
    rows = []
    for name, sev, share, long_h, short_h in ALERTS:
        burn = share * window_h / long_h
        threshold = burn * budget
        rows.append((name, share, long_h, threshold))
        print(f"{sev:6s} {name:11s}: {share:.0%} in {hours(long_h):>3s} (windows {hours(long_h)}/{hours(short_h)})  "
              f"burn {burn:6.2f}  error ratio > {threshold:.4%}  budget empty in {window_h / burn / 24:.1f} d")

    print("\n== How long the bad ratio must last before each page's long window trips")
    print("(stack running longer than the window; add the alert's 'for' and ~30 s evaluation delay)")
    for ratio in bad_ratios:
        cells = []
        for name, share, long_h, threshold in rows[:2]:
            if ratio <= threshold:
                cells.append(f"{name}: never")
            else:
                cells.append(f"{name}: {threshold * long_h * 60 / ratio:6.1f} min")
        print(f"{ratio:7.1%} bad -> " + " | ".join(cells))

    print(f"\n== Cost of a {a.spike_minutes:g}-minute incident")
    rates = [a.steady_rps] + ([a.peak_rps] if has_peak else [])
    for ratio in bad_ratios:
        for rps in rates:
            bad = rps * a.spike_minutes * 60 * ratio
            print(f"{ratio:7.1%} bad at {rps:5g} req/s: {bad:9,.0f} bad requests = {bad / allowed:7.1%} of the budget")

    rps = a.peak_rps if has_peak else a.steady_rps
    t = a.timeout_ms / 1000
    fast = a.fast_ms / 1000
    s = a.slow_share
    print(f"\n== Little's law at {rps:g} req/s (requests in flight = arrival rate x time each takes)")
    lines = [
        (f"every dependency call slow ({a.worst_slow_s:g} s), no timeout", f"{rps * a.worst_slow_s:,.0f}"),
        (f"every dependency call cut at the {a.timeout_ms:g} ms timeout", f"{rps * t:,.0f}"),
        (f"{s:.0%} of calls slow (~{a.slow_avg_s:g} s each), no timeout", f"{rps * (s * a.slow_avg_s + (1 - s) * fast):,.0f}"),
        (f"{s:.0%} of calls slow, with the {a.timeout_ms:g} ms timeout", f"{rps * (s * t + (1 - s) * fast):,.0f}"),
        ("database connections busy at ~2 ms per query", f"{rps * 0.002:.1f}"),
    ]
    for text, value in lines:
        print(f"{text + ':':58s}{value:>7s}")


if __name__ == "__main__":
    main()
