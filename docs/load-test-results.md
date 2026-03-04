# Load Test Results: Decoupled Claim + Compute Scaling

**Date:** 2026-03-03
**Migration:** `20260303200001_decouple_claim_from_queue.sql`

## Summary

We decoupled `pgmq.send` from `claim_resource_and_queue` so that the
user-facing claim path is a single `UPDATE ... FOR UPDATE SKIP LOCKED`
with no synchronous queue write.  Queue writes are now handled by a
background `sweep_reserved_to_queue` function running via `pg_cron`
every minute.

We then measured the impact locally and across four managed Supabase
compute tiers (Micro, Small, Medium, XL) using Grafana Cloud k6.

## Change

**Before:** `claim_resource_and_queue` did `UPDATE` + `pgmq.send` in
one transaction.

**After:** `claim_resource_and_queue` does only the `UPDATE`.  A new
`sweep_reserved_to_queue(batch_limit)` function runs on a cron schedule
and enqueues RESERVED slots that haven't been queued yet (tracked via a
`queued_at` column on `inventory_slots`).

## Local Results (200 VUs, loopback)

| Variant                 | avg   | median | p95   | rps   | iterations |
|-------------------------|-------|--------|-------|-------|------------|
| Before (with pgmq.send) | 117ms | 105ms  | 265ms | 1,113 | 77,974     |
| After (decoupled)       | 51ms  | 10ms   | 241ms | 1,836 | 128,535    |

**Improvement:** median -90%, avg -56%, throughput +65%.

The median dropping from 105ms to 10ms is the clearest signal: most
requests now complete almost instantly because the synchronous
`pgmq.send` is gone.  The p95 improvement is more modest (-9%) because
the tail is dominated by PostgREST overhead and index scan time under
200-VU concurrency.

## Cloud Results: Shielded (claim_resource_and_queue)

Spike scenario, 100 VUs, 70s duration, Grafana Cloud k6 runners →
Supabase managed project in us-east-1.

| Tier               | Cores | RAM  | avg       | p95       | p99        | rps     | total       | Result |
|--------------------|-------|------|-----------|-----------|------------|---------|-------------|--------|
| Micro (old impl)   | 2     | 1GB  | 182-282ms | 479-778ms | 774-1303ms | 239-342 | 19610-28032 | mixed  |
| Micro (decoupled)  | 2     | 1GB  | 196ms     | 533ms     | 860ms      | 322     | 26,440      | FAIL   |
| Small (decoupled)  | 2     | 2GB  | 136ms     | 338ms     | 524ms      | 426     | 34,930      | PASS   |
| Medium (decoupled) | 2     | 4GB  | 135ms     | 338ms     | 528ms      | 413     | 35,074      | PASS   |
| XL (decoupled)     | 4     | 16GB | 134ms     | 338ms     | 541ms      | 431     | 35,362      | PASS   |

### Grafana Cloud k6 Run IDs

| Run ID  | Test                 | Tier   | Dashboard                                                  |
|---------|----------------------|--------|------------------------------------------------------------|
| 6912496 | shielded (old)       | Micro  | https://davidventimiglia.grafana.net/a/k6-app/runs/6912496 |
| 6912881 | shielded (old)       | Micro  | https://davidventimiglia.grafana.net/a/k6-app/runs/6912881 |
| 6913088 | shielded-no-queue    | Micro  | https://davidventimiglia.grafana.net/a/k6-app/runs/6913088 |
| 6913332 | shielded (decoupled) | Micro  | https://davidventimiglia.grafana.net/a/k6-app/runs/6913332 |
| 6913413 | shielded (decoupled) | Small  | https://davidventimiglia.grafana.net/a/k6-app/runs/6913413 |
| 6913462 | shielded (decoupled) | Medium | https://davidventimiglia.grafana.net/a/k6-app/runs/6913462 |
| 6913517 | shielded (decoupled) | XL     | https://davidventimiglia.grafana.net/a/k6-app/runs/6913517 |

## Cloud Results: Unshielded (finalize_transaction on DB2)

For reference, the unshielded test (direct INSERT to DB2 via
`finalize_transaction`) was stable across all runs:

| Tier   | avg  | p95     | p99      | rps     |
|--------|------|---------|----------|---------|
| Micro  | 47ms | 68-70ms | 95-101ms | 808-810 |
| Small  | 48ms | 68ms    | 90ms     | 806     |
| Medium | 48ms | 70ms    | 102ms    | 802     |
| XL     | 34ms | 43ms    | 58ms     | 903     |

DB2 is on a separate managed project and was not scaled during this
experiment.  The slight improvement at XL is likely due to reduced
network variability during that specific run rather than a DB2 change.

## Analysis

### Decoupling pgmq.send works

Locally, removing `pgmq.send` from the hot path cut median latency by
90% and boosted throughput by 65%.  The synchronous queue write was
clearly the dominant cost in `claim_resource_and_queue`.

### Compute scaling hits a plateau at Small

In the cloud, scaling from Micro to Small produced a significant
improvement (p95: 533ms → 338ms, rps: 322 → 426).  But further scaling
to Medium and XL produced no measurable change.  The numbers are
virtually identical across Small, Medium, and XL:

- p95 locked at ~338ms
- avg locked at ~135ms
- rps locked at ~425

This plateau holds for both latency and throughput.  However,
throughput may be **load-generator-limited**, not database-limited.
At 100 VUs with ~135ms avg response time and ~50ms avg think time, the
theoretical max is ~540 rps — close to the observed ~425 rps.  The
Grafana Cloud k6 free tier caps at 100 VUs, so we cannot determine
whether larger instances would sustain higher throughput under heavier
load.  A test with more VUs (requiring a paid k6 tier or self-hosted
runners) would be needed to separate the database ceiling from the
load-generator ceiling.

For latency, the plateau is real: at 100 VUs the floor is set by
network round-trip time between the Grafana Cloud load generators and
the Supabase instance.

### Micro is undersized

The jump from Micro to Small (p95: 533ms → 338ms) suggests Micro's
1GB RAM is insufficient for this workload.  Likely cause: shared
buffers are too small, forcing more disk reads on the 500k-row
`inventory_slots` partial index scan.

### Recommendation

**Small** is the right tier for this workload at 100 VUs.  Scaling
beyond Small provides no latency benefit because the bottleneck shifts
to network round-trip time.  Whether larger tiers unlock higher
throughput remains an open question — answering it requires more than
100 concurrent VUs, which exceeds the Grafana Cloud k6 free tier.  To
push latency lower, the load generators would need to be co-located
with the database (same region, same VPC).
