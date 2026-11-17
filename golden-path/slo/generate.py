"""SLO as code: one small spec per service -> Prometheus recording rules and
multi-window, multi-burn-rate alerts (Google SRE Workbook). Teams write the
spec; nobody writes PromQL. The metric names come from the telemetry standard.

Usage: generate.sh <chart folder or slo.yaml>... [--check]
  Writes slo-rules.yaml next to each slo.yaml (in the service's chart, which ships it to
  Prometheus). --check writes nothing and fails if a slo-rules.yaml is out of date.
"""
import argparse
import pathlib
import sys

import yaml

# (alert, severity, share of the budget spent, long window, short window, for)
ALERTS = [
    ("SLOFastBurn", "page", 0.02, "1h", "5m", "1m"),
    ("SLOSlowBurn", "page", 0.05, "6h", "30m", "1m"),
    ("SLOBudgetLeak", "ticket", 0.10, "3d", "6h", "15m"),
]
# OpenTelemetry's standard HTTP latency buckets: the threshold must be one of these edges,
# or "answered within the threshold" can't be counted exactly.
BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10]


class _Plain(yaml.SafeDumper):
    """Write repeated labels out in full (no &id001 shortcuts): people read this file."""
    def ignore_aliases(self, data):
        return True


REQUIRED = ["service", "team", "route", "objective", "latency_threshold", "window", "runbook"]


def hours(window: str) -> float:
    return float(window[:-1]) * {"m": 1 / 60, "h": 1, "d": 24}[window[-1]]


def load(path: pathlib.Path) -> dict:
    spec = yaml.safe_load(path.read_text())
    problems = [f"missing '{key}'" for key in REQUIRED if key not in spec]
    chart = path.parent / "Chart.yaml"
    if not problems and chart.exists():
        name = yaml.safe_load(chart.read_text())["name"]
        if spec["service"] != name:   # the service name is the chart name, and the metrics' job label
            problems.append(f"service is {spec['service']!r} but the chart is called {name!r}: they must match")
    if not problems and not 0 < spec["objective"] < 100:
        problems.append("objective must be a percentage between 0 and 100, e.g. 99.9")
    if not problems and spec["latency_threshold"] not in BUCKETS:
        problems.append(f"latency_threshold must be one of {BUCKETS} (seconds)")
    if problems:
        sys.exit(f"{path}: " + "; ".join(problems))
    return spec


def build(spec: dict) -> tuple[list, list, float]:
    s, team, window = spec["service"], spec["team"], spec["window"]
    budget = round(1 - spec["objective"] / 100, 10)
    sel = f'job="{s}", http_route="{spec["route"]}"'

    def good(w):   # requests that were not a 5xx and answered within the threshold
        return (f'sum(rate(http_server_request_duration_seconds_bucket{{{sel}, '
                f'le="{spec["latency_threshold"]:g}", http_response_status_code!~"5.."}}[{w}]))')

    def total(w):
        return f"sum(rate(http_server_request_duration_seconds_count{{{sel}}}[{w}]))"

    label = {"service": s}
    windows = sorted({w for alert in ALERTS for w in alert[3:5]}, key=hours)
    recording = [{"record": f"slo:error_ratio:rate{w}", "labels": label,
                  "expr": f"1 - {good(w)} / {total(w)}"} for w in windows]
    # Budget left over the whole window, from small 5-minute series: only these need
    # to be kept for 28 days, not the raw data. The pipeline's policy gate reads it.
    recording += [
        {"record": "slo:good:rate5m", "labels": label, "expr": good("5m")},
        {"record": "slo:total:rate5m", "labels": label, "expr": total("5m")},
        {"record": "slo:error_budget_remaining", "labels": label,
         "expr": f'1 - (1 - sum_over_time(slo:good:rate5m{{service="{s}"}}[{window}]) / '
                 f'sum_over_time(slo:total:rate5m{{service="{s}"}}[{window}])) / {budget:g}'},
    ]

    alerts = []
    for name, severity, spent, long_w, short_w, wait in ALERTS:
        threshold = spent * hours(window) / hours(long_w) * budget
        alerts.append({
            "alert": name,
            "expr": (f'slo:error_ratio:rate{long_w}{{service="{s}"}} > {threshold:.6g} and '
                     f'slo:error_ratio:rate{short_w}{{service="{s}"}} > {threshold:.6g}'),
            "for": wait,
            "labels": {"severity": severity, "service": s, "team": team},
            "annotations": {"summary": f"{s}: at this rate {spent:.0%} of the {window} error budget goes in {long_w}",
                            "runbook_url": spec["runbook"]},
        })

    for dep in spec.get("dependencies", []):
        d, warn = dep["name"], dep["failure_ratio_warn"]
        calls = f'dependency_calls_total{{job="{s}", dependency="{d}"'
        recording.append({"record": "dependency:failure_ratio:rate10m", "labels": {"service": s, "dependency": d},
                          "expr": f'sum(rate({calls}, outcome!="ok"}}[10m])) / sum(rate({calls}}}[10m]))'})
        alerts.append({
            "alert": "DependencyFailing",   # a ticket, never a page: the SLO alerts page if users are hurt
            "expr": f'dependency:failure_ratio:rate10m{{service="{s}", dependency="{d}"}} > {warn:g}',
            "for": "2m",
            "labels": {"severity": "ticket", "service": s, "team": team, "dependency": d},
            "annotations": {"summary": f"{s}: more than {warn:.0%} of calls to {d} are failing or timing out",
                            "runbook_url": dep.get("runbook", spec["runbook"])},
        })
    return recording, alerts, budget


def header(spec: dict, path: pathlib.Path, budget: float) -> str:
    lines = [f"# GENERATED from {path.name} by golden-path/slo/generate.py. Do not edit: change {path.name}, then run",
             f"# golden-path/slo/generate.sh {path.parent}",
             f"# SLO: {spec['objective']}% of requests to {spec['route']} are good (not a 5xx, answered within "
             f"{spec['latency_threshold']:g} s), over a rolling {spec['window']}. Error budget: {budget:.4%} of requests.",
             f"# burn rate = share of the budget spent x {hours(spec['window']):g} h / long window hours:"]
    for name, severity, spent, long_w, short_w, _ in ALERTS:
        burn = spent * hours(spec["window"]) / hours(long_w)
        lines.append(f"#   {name:14s} {severity:6s} {spent:4.0%} in {long_w:3s} ({long_w}/{short_w} windows): "
                     f"burn {burn:5.2f}, error ratio > {burn * budget:.4%}")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("specs", nargs="+", type=pathlib.Path, help="chart folders, or their slo.yaml files")
    parser.add_argument("--check", action="store_true", help="write nothing; fail if a slo-rules.yaml is out of date")
    args = parser.parse_args()
    stale = []
    for path in args.specs:
        path = path / "slo.yaml" if path.is_dir() else path
        if not path.exists():
            sys.exit(f"{path} not found: every service on the golden path has one (start from the one new-service.sh made)")
        spec = load(path)
        recording, alerts, budget = build(spec)
        doc = {"groups": [{"name": f"{spec['service']}-slo-recording", "rules": recording},
                          {"name": f"{spec['service']}-slo-alerts", "rules": alerts}]}
        out = path.parent / "slo-rules.yaml"
        text = header(spec, path, budget) + yaml.dump(doc, Dumper=_Plain, sort_keys=False, width=200)
        if args.check:
            if not out.exists() or out.read_text() != text:
                stale.append(str(out))
            continue
        out.write_text(text)
        print(f"{path} -> {out}: {len(recording)} recording rules, {len(alerts)} alerts")
    if stale:
        sys.exit("out of date: " + ", ".join(stale) + ". Run golden-path/slo/generate.sh on it and commit the result.")
    if args.check:
        print("every slo-rules.yaml matches its slo.yaml")


if __name__ == "__main__":
    main()
