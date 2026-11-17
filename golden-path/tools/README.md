# Kit tools

Two small tools that come with the golden path. They need only `python3` and `curl`.

## `slo_math.py`: what your SLO means in numbers

    python3 golden-path/tools/slo_math.py --objective 99.9 --window-days 28 --steady-rps 5 --peak-rps 0

Prints your error budget (in requests and minutes), the burn-rate alert thresholds, how long a problem must last before you're paged, what an incident costs in budget, and how many requests pile up behind a slow dependency (with and without a timeout). Use it to pick a target and to answer "how bad was that?". `--help` lists every option.

## `prom.sh`: what your metrics are really called

    golden-path/tools/prom.sh names http_server
    golden-path/tools/prom.sh series <your-service>

Asks the platform's Prometheus for real metric names, labels, series counts (against the 2,000-series budget), loaded rules and firing alerts. Run it with no arguments to see every command. Open Prometheus first, in another terminal, with `scripts/ui.sh` or:

    kubectl -n platform port-forward svc/prometheus 9090
