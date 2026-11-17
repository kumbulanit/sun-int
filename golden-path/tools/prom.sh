#!/usr/bin/env bash
# prom.sh: ask the running Prometheus what really exists, before writing queries or rules.
# Usage:
#   prom.sh names [filter]        metric names (optionally only those containing <filter>)
#   prom.sh labels <metric>       label keys, how many values each has, and examples
#   prom.sh series [job]          active series per job, or per metric for one job
#   prom.sh query '<promql>'      run an instant query
#   prom.sh rules                 loaded rule groups, health and last error
#   prom.sh alerts                pending and firing alerts
#   prom.sh targets               scrape targets and their health
# Env: PROM_URL (default http://localhost:9090), SERIES_BUDGET (default 2000)
set -euo pipefail

PROM_URL="${PROM_URL:-http://localhost:9090}"
SERIES_BUDGET="${SERIES_BUDGET:-2000}"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; }
get() { curl -fsS -G "$PROM_URL$1" "${@:2}"; }

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 2; }
shift

case "$cmd" in
  names|labels|series|query|rules|alerts|targets) ;;
  *) usage; exit 2 ;;
esac

if ! curl -fsS --max-time 3 "$PROM_URL/-/ready" >/dev/null 2>&1; then
  echo "Prometheus is not reachable at $PROM_URL. Open it first: kubectl -n platform port-forward svc/prometheus 9090" >&2
  exit 3
fi

case "$cmd" in
  names)
    get /api/v1/label/__name__/values | python3 -c '
import json, sys
f = sys.argv[1]
names = [n for n in json.load(sys.stdin)["data"] if f in n]
print("\n".join(names) if names else "(no metric names match)")' "${1:-}"
    ;;

  labels)
    [ $# -ge 1 ] || { echo "usage: prom.sh labels <metric>" >&2; exit 2; }
    get /api/v1/series --data-urlencode "match[]=$1" | python3 -c '
import json, sys, collections
data = json.load(sys.stdin)["data"]
values = collections.defaultdict(set)
for s in data:
    for k, v in s.items():
        values[k].add(v)
print("%d series" % len(data))
for k in sorted(values):
    examples = ", ".join(sorted(values[k])[:6])
    print("  %-32s %5d values   e.g. %s" % (k, len(values[k]), examples))'
    ;;

  series)
    job="${1:-}"
    if [ -n "$job" ]; then
      q="sort_desc(count by (__name__) ({job=\"$job\"}))"
    else
      q='sort_desc(count by (job) ({__name__=~".+"}))'
    fi
    get /api/v1/query --data-urlencode "query=$q" | python3 -c '
import json, sys
budget, job = int(sys.argv[1]), sys.argv[2]
rows = json.load(sys.stdin)["data"]["result"]
total, over = 0, []
for r in rows:
    n = int(float(r["value"][1]))
    total += n
    key = r["metric"].get("__name__") if job else r["metric"].get("job", "(no job)")
    print("%8d  %s" % (n, key))
    if not job and n > budget:
        over.append(key)
print("%8d  total" % total)
if job and total > budget:
    over.append(job)
if over:
    print("OVER the %d-series budget: %s" % (budget, ", ".join(over)))
    sys.exit(1)
print("within the %d-series budget" % budget)' "$SERIES_BUDGET" "$job"
    ;;

  query)
    [ $# -ge 1 ] || { echo "usage: prom.sh query '<promql>'" >&2; exit 2; }
    get /api/v1/query --data-urlencode "query=$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
if d["resultType"] == "vector":
    if not d["result"]:
        print("(no data)")
    for r in d["result"]:
        m = dict(r["metric"])
        name = m.pop("__name__", "")
        labels = ",".join("%s=\"%s\"" % (k, v) for k, v in sorted(m.items()))
        print("%s{%s}  %s" % (name, labels, r["value"][1]))
else:
    print(json.dumps(d["result"], indent=1))'
    ;;

  rules)
    get /api/v1/rules | python3 -c '
import json, sys
groups = json.load(sys.stdin)["data"]["groups"]
if not groups:
    print("(no rules loaded)")
for g in groups:
    print("%s  (%s)" % (g["name"], g["file"]))
    for r in g["rules"]:
        err = r.get("lastError", "")
        print("  %-9s %-55s %-3s %s" % (r["type"], r["name"], r.get("health", ""), ("ERROR: " + err) if err else ""))'
    ;;

  alerts)
    get /api/v1/alerts | python3 -c '
import json, sys
alerts = json.load(sys.stdin)["data"]["alerts"]
if not alerts:
    print("(no pending or firing alerts)")
for a in alerts:
    l = a["labels"]
    print("%-8s %-45s severity=%-7s since %s" % (a["state"], l.get("alertname"), l.get("severity", "-"), a.get("activeAt", "")))'
    ;;

  targets)
    get /api/v1/targets | python3 -c '
import json, sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print("%-7s %-30s %s %s" % (t["health"], t["labels"].get("job"), t["scrapeUrl"], t.get("lastError", "")))'
    ;;
esac
