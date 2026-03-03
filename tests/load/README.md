# Load Tests

Validates the central value proposition: **DB2 shielded by DB1 survives burst load that destroys DB2 unshielded.**

## Prerequisites

- Both Supabase instances running: `cd db1 && supabase start` and `cd db2 && supabase start`
- k6 installed: `brew install k6`
- Deno installed: `brew install deno`

## Quick start

```bash
# Run spike scenario (default): shielded then unshielded, back to back
./tests/load/run.sh spike

# Or run ramp / sustained
./tests/load/run.sh ramp
./tests/load/run.sh sustained
```

Results land in `tests/load/results/`.

## With metrics poller (recommended for shielded run)

Open two terminals:

**Terminal 1 — metrics poller:**
```bash
deno run --allow-net --allow-env tests/load/metrics-poller.ts \
  > tests/load/results/metrics-$(date +%s).csv
```

**Terminal 2 — k6:**
```bash
psql "postgresql://postgres:postgres@127.0.0.1:54342/postgres" \
  -f tests/load/setup.sql
k6 run -e SCENARIO=spike \
  --out json=tests/load/results/shielded-spike.json \
  tests/load/shielded.js
```

The CSV from the metrics poller shows `db1_queue_depth` spiking during the burst and `db2_confirmed_total` growing steadily afterward — the visual proof of burst absorption.

## Scenario reference

| Scenario | Pattern | Duration | Peak VUs |
|----------|---------|----------|----------|
| `spike` | 0 → 200 VUs instantly, hold | ~70s | 200 |
| `ramp` | Step up 25→50→100→200 VUs | ~150s | 200 |
| `sustained` | Flat 100 VUs | 3m | 100 |

> **Note:** These VU counts are tuned for local Supabase dev (PostgREST connection ceiling ~200 VUs). For hosted Supabase, increase spike target to 500+ and sustained to 200+.

## What to look for

| Metric | Shielded (DB1) | Unshielded (DB2) |
|--------|---------------|-----------------|
| `http_req_duration p95` | Should stay flat under load | Will spike as DB2 saturates |
| `http_req_failed` | Near 0% | May rise as connections queue |
| `sold_out_responses` | 0 (500k pool) | n/a |
| `db1_queue_depth` (poller) | Spikes during burst, drains after | n/a |
| `db2_confirmed_total` (poller) | Grows steadily after burst | Grows erratically during burst |

## Running against Grafana Cloud k6

1. Install the k6 Cloud CLI: `k6 cloud login`
2. Replace `k6 run` with `k6 cloud run` in the commands above
3. Pass real DB URLs (accessible from k6 Cloud) via `-e DB1_URL=...` and `-e DB2_URL=...`
4. Results and charts appear in https://app.k6.io

## Manual teardown

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54342/postgres" \
  -f tests/load/teardown.sql
psql "postgresql://postgres:postgres@127.0.0.1:54442/postgres" \
  -c "DELETE FROM confirmed_tickets WHERE pool_id = 'load_test';"
```
