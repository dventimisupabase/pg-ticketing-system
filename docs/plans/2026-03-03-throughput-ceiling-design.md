# Throughput Ceiling Test Design

**Date:** 2026-03-03
**Goal:** Find the true throughput ceiling of `claim_resource_and_queue` on a managed Supabase Large/XL instance using paid Grafana Cloud k6.

## Context

Previous load tests focused on latency optimization (decoupling `pgmq.send` from the claim path). Throughput plateaued at ~425 rps with 100 VUs on the Grafana Cloud k6 free tier. The analysis noted this was likely load-generator-limited, not database-limited. This test removes that bottleneck.

## Approach: Stepped VU Ramp

Run a single k6 cloud test with increasing VU counts, holding at each level long enough (60s) for throughput to stabilize. The ceiling is the VU level where rps stops growing linearly.

```
VU profile:  100 ──hold──→ 200 ──hold──→ 500 ──hold──→ 1000 ──hold──→ 2000 ──hold──→ 0
Duration:     10s   60s     10s   60s     10s   60s      10s   60s      10s   60s     10s
```

Total duration: ~370s (~6 minutes).

## Deliverables

### 1. `tests/load/throughput-ceiling.js`

New k6 script with:
- `ramping-vus` executor, 10 stages (5 ramps + 5 holds)
- No think time (remove `sleep`) to maximize per-VU throughput
- Relaxed thresholds (p95 < 2000ms) since we're deliberately pushing to saturation
- Cloud options: co-located runners in us-east-1 Ashburn
- Imports shared config for URLs, headers, pool ID, custom metrics

### 2. `tests/load/run-throughput-ceiling.sh`

Cloud runner script that:
1. Sources `.env.cloud` for credentials
2. Seeds 1M inventory slots (100 batches of 10k via REST API)
3. Runs `k6 cloud run` with `throughput-ceiling.js`
4. Captures run ID
5. Tears down

### 3. Updated `docs/load-test-results.md`

New section with:
- Table: VU level → avg, median, p95, p99, rps, total iterations
- Saturation point identification
- Bottleneck analysis (PostgREST connection pool, Postgres CPU, or platform limits)
- Updated recommendation

## What We're NOT Doing

- Not changing DB1 schema or functions — measurement only
- Not testing bridge worker or DB2 — just the claim hot path
- Not modifying existing test scripts (`shielded.js`, `unshielded.js`)
- Not changing Supabase compute tier — testing on current Large/XL

## Key Design Decisions

- **No think time:** The existing `sleep(Math.random() * 0.1)` caps per-VU throughput at ~20 rps. Removing it lets each VU fire as fast as the server responds, giving a true ceiling measurement.
- **Separate script:** Keeps existing spike/ramp/sustained scenarios untouched. The throughput ceiling test has different goals (saturation, not latency shape).
- **1M slots:** At 2000 VUs with ~60s hold and optimistic ~2000 rps, that's ~120k claims per step, ~600k total. 1M provides margin.
- **60s hold per step:** Long enough for rps to stabilize and for Grafana to show a clear plateau in the time-series chart.

## Environment

- **DB1:** Managed Supabase, Large/XL tier (4+ cores, 8GB+ RAM), us-east-1
- **Load generator:** Paid Grafana Cloud k6, runners pinned to us-east-1 Ashburn
- **Pool:** `load_test`, 1M AVAILABLE slots
