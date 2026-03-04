# Throughput Ceiling Test Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a k6 cloud test that finds the true throughput ceiling of `claim_resource_and_queue` on a managed Supabase Large/XL instance by stepping VUs from 100 to 2000.

**Architecture:** A single k6 script with a stepped `ramping-vus` profile (100→200→500→1000→2000 VUs, 60s hold per step). No think time. Co-located runners in us-east-1. A companion shell script seeds 1M slots and runs the test via `k6 cloud run`.

**Tech Stack:** k6 (Grafana Cloud, paid tier), Bash, existing `tests/load/lib/config.js` for shared config

---

## Task 1: Create the k6 throughput ceiling script

**Files:**
- Create: `tests/load/throughput-ceiling.js`

**Step 1: Write the script**

Create `tests/load/throughput-ceiling.js`:

```javascript
// tests/load/throughput-ceiling.js
// Throughput ceiling test: stepped VU ramp to find max rps of claim_resource_and_queue.
// Run via: ./tests/load/run-throughput-ceiling.sh

import http from 'k6/http';
import { check } from 'k6';
import {
  DB1_URL, DB1_HEADERS, POOL_ID,
  soldOutCounter, claimDuration,
} from './lib/config.js';

// Stepped VU ramp: 100 → 200 → 500 → 1000 → 2000, 60s hold per step.
// No think time — each VU fires as fast as the server responds.
export const options = {
  scenarios: {
    throughput_ceiling: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s',  target: 100 },   // ramp to 100
        { duration: '60s',  target: 100 },   // hold
        { duration: '10s',  target: 200 },   // ramp to 200
        { duration: '60s',  target: 200 },   // hold
        { duration: '10s',  target: 500 },   // ramp to 500
        { duration: '60s',  target: 500 },   // hold
        { duration: '10s',  target: 1000 },  // ramp to 1000
        { duration: '60s',  target: 1000 },  // hold
        { duration: '10s',  target: 2000 },  // ramp to 2000
        { duration: '60s',  target: 2000 },  // hold
        { duration: '10s',  target: 0 },     // ramp down
      ],
    },
  },
  thresholds: {
    http_req_failed:   ['rate<0.05'],    // <5% errors (generous — we expect saturation)
    http_req_duration: ['p(95)<2000'],   // p95 under 2s (generous — measuring ceiling)
  },
  cloud: {
    distribution: {
      ashburn: { loadZone: 'amazon:us:ashburn', percent: 100 },
    },
  },
};

export default function () {
  const userId = `vu_${__VU}_iter_${__ITER}`;

  const start = Date.now();
  const res = http.post(
    `${DB1_URL}/rest/v1/rpc/claim_resource_and_queue`,
    JSON.stringify({ p_pool_id: POOL_ID, p_user_id: userId }),
    { headers: DB1_HEADERS },
  );
  claimDuration.add(Date.now() - start);

  check(res, {
    'status is 200': (r) => r.status === 200,
  });

  if (res.body === 'null' || res.body === '') {
    soldOutCounter.add(1);
  }

  // No sleep — maximize per-VU throughput to find the true ceiling.
}
```

**Step 2: Verify no syntax errors locally**

Run:
```bash
k6 run --dry-run tests/load/throughput-ceiling.js
```

Expected: No JavaScript syntax errors. Will warn about cloud options locally — that's fine.

**Step 3: Commit**

```bash
git add tests/load/throughput-ceiling.js
git commit -m "test(load): add k6 throughput ceiling script (stepped VU ramp to 2000)"
```

---

## Task 2: Create the cloud runner script

**Files:**
- Create: `tests/load/run-throughput-ceiling.sh`

**Step 1: Write the script**

Create `tests/load/run-throughput-ceiling.sh`. Pattern follows `run-cloud.sh` but simpler — one test, 1M slots:

```bash
#!/usr/bin/env bash
# tests/load/run-throughput-ceiling.sh
# Throughput ceiling test: find max rps of claim_resource_and_queue on managed Supabase.
# Usage: ./tests/load/run-throughput-ceiling.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.cloud"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy .env.cloud.example and fill in cloud credentials."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${DB1_URL:?DB1_URL must be set in .env.cloud}"
: "${DB1_KEY:?DB1_KEY must be set in .env.cloud}"
: "${K6_CLOUD_TOKEN:?K6_CLOUD_TOKEN must be set in .env.cloud}"

PROJECT_ID=6883841

latest_run_id() {
  curl -sf "https://api.k6.io/cloud/v5/projects/$PROJECT_ID/test_runs" \
    -H "Authorization: Token $K6_CLOUD_TOKEN" | \
    python3 -c "
import sys, json
runs = json.load(sys.stdin)['value']
print(sorted(runs, key=lambda r: r.get('started',''), reverse=True)[0]['id'])
"
}

# --- REST helpers (same pattern as run-cloud.sh) ---
db1_post() { curl -sf -X POST "$DB1_URL/rest/v1/$1" \
  -H "apikey: $DB1_KEY" -H "Authorization: Bearer $DB1_KEY" \
  -H "Content-Type: application/json" -H "Prefer: $2" -d "$3"; }

db1_delete() { curl -sf -X DELETE "$DB1_URL/rest/v1/$1" \
  -H "apikey: $DB1_KEY" -H "Authorization: Bearer $DB1_KEY"; }

echo "=== Throughput ceiling test ($(date)) ==="

# --- Setup: 1M inventory slots ---
echo "--- Setting up load_test pool on cloud DB1 (1M slots) ---"

db1_post "engine_config" "resolution=ignore-duplicates" \
  '{"pool_id":"load_test","batch_size":100,"visibility_timeout_sec":45,"max_retries":10,"is_active":true}'

db1_delete "inventory_slots?pool_id=eq.load_test"

echo "    Inserting 1M inventory slots (100 batches of 10k)..."
BATCH=$(python3 -c "import json; print(json.dumps([{'pool_id':'load_test','status':'AVAILABLE'}]*10000))")
for i in $(seq 1 100); do
  db1_post "inventory_slots" "return=minimal" "$BATCH" > /dev/null
  printf "    %d/100\r" "$i"
done
echo ""

# Verify slot count
SLOT_COUNT=$(curl -sf "$DB1_URL/rest/v1/inventory_slots?pool_id=eq.load_test&status=eq.AVAILABLE&select=count" \
  -H "apikey: $DB1_KEY" -H "Authorization: Bearer $DB1_KEY" \
  -H "Prefer: count=exact" -H "Range-Unit: items" -H "Range: 0-0" \
  -I 2>/dev/null | grep -i content-range | grep -oE '[0-9]+$' || echo "unknown")
echo "    Slot count: $SLOT_COUNT"

# --- Run ---
echo "--- Running throughput ceiling test (k6 cloud) ---"
RUN_EXIT=0
k6 cloud run \
  -e DB1_URL="$DB1_URL" \
  -e DB1_KEY="$DB1_KEY" \
  "$SCRIPT_DIR/throughput-ceiling.js" || RUN_EXIT=$?
RUN_ID=$(latest_run_id)

# --- Teardown ---
echo "--- Tearing down ---"
db1_delete "inventory_slots?pool_id=eq.load_test"
db1_delete "engine_metrics?pool_id=eq.load_test"

echo ""
echo "=== Results ==="
echo "    Run ID : $RUN_ID"
echo "    Exit   : $RUN_EXIT  (0=pass, 99=thresholds crossed)"
echo "    Dashboard: https://app.k6.io"
echo ""
echo "Download results:"
echo "    ./tests/load/download-results.sh $RUN_ID"
```

**Step 2: Make executable**

```bash
chmod +x tests/load/run-throughput-ceiling.sh
```

**Step 3: Verify the script parses correctly**

```bash
bash -n tests/load/run-throughput-ceiling.sh && echo "Syntax OK"
```

Expected: `Syntax OK`

**Step 4: Commit**

```bash
git add tests/load/run-throughput-ceiling.sh
git commit -m "test(load): add cloud runner for throughput ceiling test (1M slots)"
```

---

## Task 3: Update load test README

**Files:**
- Modify: `tests/load/README.md`

**Step 1: Add throughput ceiling section**

Add after the existing "Scenario reference" section in `tests/load/README.md`:

```markdown
## Throughput ceiling test

Finds the maximum rps of `claim_resource_and_queue` on managed Supabase by stepping VUs from 100 to 2000.

**Requires:** Paid Grafana Cloud k6 (>100 VU limit), `.env.cloud` configured.

```bash
./tests/load/run-throughput-ceiling.sh
```

Seeds 1M slots, runs a stepped ramp (100→200→500→1000→2000 VUs, 60s hold per step), tears down. Total duration ~6 minutes.

No think time — each VU fires as fast as the server responds. The saturation point is where rps stops growing with more VUs.

| Step | VUs  | Duration |
|------|------|----------|
| 1    | 100  | 60s hold |
| 2    | 200  | 60s hold |
| 3    | 500  | 60s hold |
| 4    | 1000 | 60s hold |
| 5    | 2000 | 60s hold |
```

**Step 2: Commit**

```bash
git add tests/load/README.md
git commit -m "docs: add throughput ceiling test to load test README"
```

---

## Task 4: Run the test and record results

This task is manual — run the actual test and update docs.

**Step 1: Run the throughput ceiling test**

```bash
./tests/load/run-throughput-ceiling.sh
```

Expected: ~6 minutes of k6 cloud execution. Watch the Grafana dashboard for rps time-series.

**Step 2: Download results**

```bash
./tests/load/download-results.sh <RUN_ID>
```

**Step 3: Update `docs/load-test-results.md`**

Add a new section "## Throughput Ceiling: Stepped VU Ramp" with:
- Table: VU level → avg, median, p95, p99, rps, total iterations
- Saturation point (where rps stops growing)
- Bottleneck analysis
- Updated recommendation

Read per-step metrics from the Grafana Cloud k6 dashboard or downloaded time-series JSON. Each 60s hold period gives a clean window to extract steady-state metrics per VU level.

**Step 4: Commit**

```bash
git add docs/load-test-results.md
git commit -m "docs: add throughput ceiling test results"
```

---

## Phase Sequencing Summary

| Task | Deliverable | Verifiable? |
|------|-------------|-------------|
| 1 | `throughput-ceiling.js` | `k6 run --dry-run` passes |
| 2 | `run-throughput-ceiling.sh` | `bash -n` passes |
| 3 | README update | Section visible in README |
| 4 | Test results in docs | rps-per-VU-level table in `load-test-results.md` |
