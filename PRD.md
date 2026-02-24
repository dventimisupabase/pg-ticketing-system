# Product Requirements Document: Supabase Intake Engine

**Project:** pg-ticketing-system
**Date:** 2026-02-24
**Status:** Draft

---

## 1. Overview

The repo contains an architectural blueprint for a high-concurrency ticketing system (the "Burst-to-Queue Ledger" pattern), but only ~60% is implemented. Three files exist:

- `gemini_docs.md` — pitch/spec doc
- `001_intake_engine_setup.sql` — partial DB1 migration with known bugs
- `bridge_worker.ts` — bridge worker with stubs and outdated patterns

The goal is a **production-ready reference implementation** — complete, deployable, tested, and forkable. We follow TDD: failing tests first, then implementation.

---

## 2. Problem Statement

The existing codebase provides a partial implementation of the "Burst-to-Queue Ledger" pattern described in `gemini_docs.md`. The current state has:

- Known bugs in the SQL migration (hardcoded pool names, missing columns, no DLQ)
- An outdated bridge worker using deprecated imports and anti-patterns
- No test coverage
- No Supabase project scaffolding
- Missing DB2 ledger (confirmed tickets) schema

This PRD defines the complete plan to bring the implementation to production-ready status.

---

## 3. Key Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **No `processing_state` table** | pgmq's `read_ct` tracks retries; payload `state` field handles resume-on-retry. Eliminates a synchronization surface. |
| 2 | **Manual DLQ via `intake_dlq` queue** | pgmq has no automatic DLQ. Bridge worker checks `read_ct >= max_retries` and routes via `intake_route_to_dlq()` RPC. |
| 3 | **Two Supabase JS clients** | DB1 and DB2 are separate Supabase instances. Bridge worker holds one client per database. Faithful to the spec's two-database architecture. |
| 4 | **pgmq RPC wrappers** | PostgREST can't call pgmq extension functions directly. Thin SQL wrappers (`intake_queue_read`, `intake_queue_delete`, etc.) expose them as RPCs. |
| 5 | **Simplified DB2 schema** | `confirmed_tickets` table with `resource_id` as PK and idempotent ON CONFLICT. Pluggable via `commit_rpc_name` (Supabase DB2) or `commit_webhook_url` (legacy DB2 behind HTTP). |
| 6 | **No FK from engine_config to inventory_slots** | Config should be deployable before inventory is populated. |
| 7 | **`current_setting()` for cron job URLs** | Instead of hardcoded URLs/keys in pg_cron jobs. Set via `ALTER DATABASE` or Supabase dashboard. |
| 8 | **queue_depth is global, not per-pool** | pgmq metrics are per-queue. Per-pool would require scanning message payloads — too expensive under load. |
| 9 | **Pluggable DB2 commit interface** | `commit_webhook_url` in engine_config enables legacy DB2 customers. Bridge worker: if webhook URL set → HTTP POST; else → `db2.rpc()`. Mirrors the existing `validation_webhook_url` pattern. Webhook must return 2xx for success; `resource_id` in payload serves as idempotency key. |

---

## 4. Bugs Fixed from Existing Code

### SQL (`001_intake_engine_setup.sql`)

1. **CRITICAL**: `snapshot_engine_metrics()` hardcodes `'taylor_swift_la_night_1'` — replaced with dynamic iteration over all active pools from `engine_config`
2. **MEDIUM**: Redundant `CONSTRAINT unique_slot UNIQUE (id)` on a PK column — removed
3. **MEDIUM**: `engine_metrics` has no PK or indexes — added `BIGINT GENERATED ALWAYS AS IDENTITY` PK and `(pool_id, captured_at DESC)` index
4. **HIGH**: `engine_config` missing columns from spec — added `visibility_timeout_sec`, `max_retries`, `validation_webhook_url`, `commit_rpc_name`, `commit_webhook_url`
5. **HIGH**: No DLQ queue — added `SELECT pgmq.create('intake_dlq')`

### Bridge Worker (`bridge_worker.ts`)

1. **CRITICAL**: Import `https://deno.land/x/postgresjs/mod.js` is outdated — use `jsr:@supabase/supabase-js@2`
2. **HIGH**: Closes connection pools in `finally` on every invocation — anti-pattern for Edge Functions. Supabase JS client is module-level, no teardown needed.
3. **HIGH**: No DLQ logic — added `read_ct` check against `max_retries`, routes via `intake_route_to_dlq` RPC
4. **HIGH**: No timeout protection — added `Promise.race` with 50s guard
5. **MEDIUM**: Basic console.log — replaced with structured JSON logging including `msg_id` and `pool_id`
6. **HIGH**: Two raw postgres pools — replaced with two Supabase JS clients (one per database). The fix is the import/driver, not the count.

---

## 5. Target Project Structure

```
pg-ticketing-system/
  gemini_docs.md                       (existing — kept as-is)
  001_intake_engine_setup.sql          (original — kept for reference)
  bridge_worker.ts                     (original — kept for reference)
  PRD.md
  .env.example
  db1/                                 (DB1: Intake Engine)
    supabase/
      config.toml                      (default ports: API 54321, DB 54322, Studio 54323)
      seed.sql
      migrations/
        20260224100000_intake_engine_setup.sql
        20260224100001_intake_engine_functions.sql
        20260224100002_intake_engine_cron.sql
      functions/
        bridge-worker/index.ts
        admin-dlq/index.ts
      tests/
        00001_intake_tables.test.sql
        00002_intake_functions.test.sql
        00003_intake_cron.test.sql
  db2/                                 (DB2: Core Ledger)
    supabase/
      config.toml                      (offset ports: API 54421, DB 54422, Studio 54423)
      seed.sql
      migrations/
        20260224100000_db2_ledger.sql
      tests/
        00001_db2_ledger.test.sql
```

---

## 6. Implementation Phases

### Phase 0: Project Scaffolding

**Goal:** Two Supabase project structures + local dev environment.

**Steps:**

1. Install Deno: `brew install deno`
2. Run `supabase init` in both `db1/` and `db2/`
3. Edit `db1/supabase/config.toml` — default ports, enable required extensions (pgmq, pg_cron, pg_net, pgtap)
4. Edit `db2/supabase/config.toml` — offset ports (+100: API 54421, DB 54422, Studio 54423), enable pgtap (no pgmq/pg_cron/pg_net needed)
5. Run `cd db1 && supabase start` — verify all services boot
6. Run `cd db2 && supabase start` — verify all services boot
7. Confirm `cd db1 && supabase test db` runs (reports "no tests found")
8. Confirm `cd db2 && supabase test db` runs (reports "no tests found")
9. Create `.env.example`:
   ```
   DB1_SUPABASE_URL=http://127.0.0.1:54321
   DB1_SUPABASE_ANON_KEY=<from db1 supabase status>
   DB1_SUPABASE_SERVICE_ROLE_KEY=<from db1 supabase status>
   DB2_SUPABASE_URL=http://127.0.0.1:54421
   DB2_SUPABASE_ANON_KEY=<from db2 supabase status>
   DB2_SUPABASE_SERVICE_ROLE_KEY=<from db2 supabase status>
   ```

**Acceptance:** `supabase status` shows all services running for both DB1 and DB2.

---

### Phase 1: pgTAP Tests for Tables & Types (TDD Red)

**Goal:** Write failing tests that define the expected schema.

**File:** `db1/supabase/tests/00001_intake_tables.test.sql`

**Tests:**

- Extensions exist: pgmq, pg_cron, pg_net
- Type `slot_status` exists with labels `AVAILABLE`, `RESERVED`, `CONSUMED`
- `inventory_slots` table: columns (id, pool_id, status, locked_by, locked_at), PK on id, partial index `idx_available_slots`
- `engine_config` table: columns (pool_id, batch_size, visibility_timeout_sec, max_retries, is_active, validation_webhook_url, commit_rpc_name, commit_webhook_url), PK on pool_id
- `engine_metrics` table: has PK, has index `idx_metrics_pool_ts`
- pgmq queues exist: `intake_queue`, `intake_dlq`

**Acceptance:** `cd db1 && supabase test db` — all tests FAIL (red).

---

### Phase 2: Migration — Tables, Types, Extensions (TDD Green)

**Goal:** Make Phase 1 tests pass.

**File:** `db1/supabase/migrations/20260224100000_intake_engine_setup.sql`

**Contents:**

```sql
-- Extensions
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Queues
SELECT pgmq.create('intake_queue');
SELECT pgmq.create('intake_dlq');

-- Types
CREATE TYPE slot_status AS ENUM ('AVAILABLE', 'RESERVED', 'CONSUMED');

-- Tables
CREATE UNLOGGED TABLE inventory_slots (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    pool_id   TEXT NOT NULL,
    status    slot_status NOT NULL DEFAULT 'AVAILABLE',
    locked_by TEXT,
    locked_at TIMESTAMPTZ
);
-- NO redundant UNIQUE constraint

CREATE INDEX idx_available_slots
    ON inventory_slots (pool_id, status)
    WHERE status = 'AVAILABLE';

CREATE TABLE engine_config (
    pool_id                TEXT PRIMARY KEY,
    batch_size             INT NOT NULL DEFAULT 100,
    visibility_timeout_sec INT NOT NULL DEFAULT 45,
    max_retries            INT NOT NULL DEFAULT 10,
    is_active              BOOLEAN NOT NULL DEFAULT true,
    validation_webhook_url TEXT,
    commit_rpc_name        TEXT NOT NULL DEFAULT 'finalize_transaction',
    commit_webhook_url     TEXT
);

CREATE TABLE engine_metrics (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    pool_id         TEXT NOT NULL,
    available_slots INT NOT NULL,
    reserved_slots  INT NOT NULL,
    consumed_slots  INT NOT NULL,
    queue_depth     INT NOT NULL,
    dlq_depth       INT NOT NULL DEFAULT 0
);

CREATE INDEX idx_metrics_pool_ts
    ON engine_metrics (pool_id, captured_at DESC);
```

**Acceptance:** `cd db1 && supabase test db` — Phase 1 tests PASS (green).

---

### Phase 3: Functions — Tests Then Implementation

#### Phase 3a: pgTAP Tests (Red)

**File:** `db1/supabase/tests/00002_intake_functions.test.sql`

**Tests:**

- `claim_resource_and_queue('pool', 'user')` returns UUID when slots available
- Claimed slot has `status = 'RESERVED'`, correct `locked_by`
- Message enqueued in `intake_queue` (verify via `pgmq.metrics`)
- Returns NULL when sold out (all slots claimed)
- Queue depth matches total claims
- `intake_queue_read(vt, qty)` returns messages
- `intake_queue_send(payload)` returns a msg_id
- `intake_route_to_dlq(msg_id, payload, read_ct)` moves message to DLQ
- `snapshot_engine_metrics()` inserts one row per active pool
- Metrics row has correct `available_slots`, `reserved_slots` counts

#### Phase 3b: Migration (Green)

**File:** `db1/supabase/migrations/20260224100001_intake_engine_functions.sql`

**Functions:**

1. **`claim_resource_and_queue(p_pool_id, p_user_id) RETURNS UUID`**
   - Same SKIP LOCKED pattern as original (verified correct)
   - Payload includes `pool_id`, `resource_id`, `user_id`, `state='queued'`

2. **`intake_queue_read(p_visibility_timeout, p_batch_size) RETURNS TABLE`**
   - Wraps `pgmq.read('intake_queue', vt, qty)` — returns `msg_id, read_ct, enqueued_at, vt, message`

3. **`intake_queue_delete(p_msg_ids BIGINT[]) RETURNS SETOF BIGINT`**
   - Wraps `pgmq.delete('intake_queue', msg_ids)`

4. **`intake_queue_send(p_payload JSONB) RETURNS BIGINT`**
   - Wraps `pgmq.send('intake_queue', payload)` — used by claim function and tests

5. **`intake_route_to_dlq(p_msg_id, p_payload, p_read_ct) RETURNS BIGINT`**
   - Enriches payload with failure metadata (`original_msg_id`, `final_read_ct`, `routed_to_dlq_at`)
   - Sends to `intake_dlq` queue, deletes from `intake_queue`

6. **`snapshot_engine_metrics() RETURNS VOID`** (FIXED)
   - Iterates all active pools from `engine_config`
   - Uses `COUNT(*) FILTER (WHERE status = ...)` grouped by pool
   - Captures `available_slots`, `reserved_slots`, `consumed_slots`, `queue_depth`, `dlq_depth`
   - Note: `queue_depth` and `dlq_depth` are global (not per-pool) since pgmq metrics are per-queue

**Acceptance:** `cd db1 && supabase test db` — Phase 3a tests PASS.

---

### Phase 4: Slot Reaper & Cron Jobs — Tests Then Implementation

#### Phase 4a: pgTAP Tests (Red)

**File:** `db1/supabase/tests/00003_intake_cron.test.sql`

**Tests:**

- `reap_orphaned_slots(interval)` function exists
- A RESERVED slot older than threshold with no queue message -> becomes AVAILABLE, locked_by/locked_at cleared
- A RESERVED slot with a matching queue message -> NOT reaped (stays RESERVED)
- Returns count of reaped slots

#### Phase 4b: Migration (Green)

**File:** `db1/supabase/migrations/20260224100002_intake_engine_cron.sql`

**Functions:**

1. **`reap_orphaned_slots(p_stale_threshold INTERVAL DEFAULT '10 minutes') RETURNS INT`**
   - Finds `inventory_slots` with `status = 'RESERVED'` AND `locked_at < now() - threshold`
   - AND no matching row in `pgmq.q_intake_queue` (the underlying queue table) where `message->>'resource_id' = slot.id`
   - Uses `FOR UPDATE SKIP LOCKED` to avoid contention
   - Resets to `AVAILABLE`, clears `locked_by`/`locked_at`
   - Returns count of reaped rows

**Cron schedules:**

- `metrics_snapshot`: every minute -> `SELECT snapshot_engine_metrics()`
- `reap_orphaned_slots`: every 2 minutes -> `SELECT reap_orphaned_slots(interval '10 minutes')`
- `drain_queue_trigger`: every minute -> `SELECT net.http_post(...)` using `current_setting('app.bridge_worker_url')` and `current_setting('app.service_role_key')`. URL must point to DB1's edge function URL (`http://127.0.0.1:54321/functions/v1/bridge-worker`).

**Acceptance:** `cd db1 && supabase test db` — Phase 4a tests PASS.

---

### Phase 5: DB2 Ledger — Tests Then Implementation

#### Phase 5a: pgTAP Tests (Red)

**File:** `db2/supabase/tests/00001_db2_ledger.test.sql`

**Tests:**

- `confirmed_tickets` table exists with PK on `resource_id`
- `finalize_transaction(payload)` inserts a row with correct `user_id`
- Idempotency: calling `finalize_transaction` twice with same `resource_id` -> no error, one row
- RLS: `confirmed_tickets` has row security enabled

Note: DB2's `finalize_transaction` does NOT update `inventory_slots` — that table lives on DB1. The bridge worker handles cross-database coordination.

#### Phase 5b: Migration (Green)

**File:** `db2/supabase/migrations/20260224100000_db2_ledger.sql`

**Tables:**

```sql
CREATE TABLE confirmed_tickets (
    resource_id   UUID PRIMARY KEY,
    pool_id       TEXT NOT NULL,
    user_id       TEXT NOT NULL,
    confirmed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Functions:**

1. **`finalize_transaction(p_payload JSONB) RETURNS VOID`**
   - Extracts `resource_id`, `pool_id`, `user_id` from payload
   - `INSERT INTO confirmed_tickets ... ON CONFLICT (resource_id) DO NOTHING` (idempotent)
   - Does NOT update `inventory_slots` (that table is on DB1; the bridge worker handles the cross-database update)

**RLS + Realtime:**

- `ALTER PUBLICATION supabase_realtime ADD TABLE confirmed_tickets`
- RLS enabled: `auth.uid()::text = user_id` for SELECT
- INSERTs only via `finalize_transaction` (service role context)

**Acceptance:** `cd db2 && supabase test db` — Phase 5a tests PASS.

---

### Phase 6: Edge Functions — Bridge Worker + DLQ Admin

#### 6a: Bridge Worker (Complete Rewrite)

**File:** `db1/supabase/functions/bridge-worker/index.ts`

**Key design:**

- Import: `jsr:@supabase/supabase-js@2`
- Two module-level clients (never torn down):
  ```typescript
  const db1 = createClient(Deno.env.get('DB1_SUPABASE_URL')!, Deno.env.get('DB1_SUPABASE_SERVICE_ROLE_KEY')!);
  const db2 = createClient(Deno.env.get('DB2_SUPABASE_URL')!, Deno.env.get('DB2_SUPABASE_SERVICE_ROLE_KEY')!);
  ```
- `Promise.race` timeout guard (50s)
- Structured JSON logging with `msg_id`, `pool_id` on every line
- Per-message processing loop:
  1. Read queue from DB1 (`db1.rpc('intake_queue_read', ...)`)
  2. Fetch pool config from DB1's `engine_config` (cached per invocation)
  3. Check `read_ct >= max_retries` -> route to DLQ via DB1's `intake_route_to_dlq` RPC
  4. If `state === 'queued'` and webhook URL configured -> POST to webhook with idempotency key
  5. If `state === 'queued'` and no webhook -> skip validation, set `state = 'validated'`
  6. Commit to DB2:
     - If `config.commit_webhook_url` is set → HTTP POST to that URL with JSON payload
       (headers: Content-Type: application/json, X-Idempotency-Key: resource_id)
       - 2xx → success
       - non-2xx → throw (message stays on queue for retry)
     - Else → `db2.rpc(config.commit_rpc_name, { p_payload })` (Supabase DB2)
     - Note: the `db2` client initialization should be lazy/conditional — only created if any pool config lacks a `commit_webhook_url`. This avoids requiring DB2 env vars when all pools use webhooks.
  7. On DB2 success -> update slot status on DB1 (`db1.from('inventory_slots').update({ status: 'CONSUMED' }).eq('id', resource_id).eq('status', 'RESERVED')`)
  8. Add to acknowledgement list
- Batch delete acknowledged messages from DB1 queue via `intake_queue_delete` RPC
- Response: `{ status, processed, dlq, total }`

**Error handling must distinguish DB1 vs DB2 failures:**

- DB2 failure -> message stays on DB1 queue, retried later (core resilience pattern)
- Webhook failure (non-2xx or network error) -> same as DB2 failure: message stays on DB1 queue, retried later
- DB1 failure -> log and abort (can't read queue anyway)

#### 6b: DLQ Admin API

**File:** `db1/supabase/functions/admin-dlq/index.ts`

**Endpoints (via request method + URL path):**

- `GET /admin-dlq?pool_id=X` — read from `intake_dlq` queue, filter by pool_id in payload
- `POST /admin-dlq/replay` body `{ msg_ids: [...] }` — read DLQ messages, re-send to `intake_queue` via `intake_queue_send`, delete from DLQ
- `POST /admin-dlq/discard` body `{ msg_ids: [...] }` — archive/delete from DLQ permanently
- Auth: require `Authorization: Bearer <service_role_key>` header

#### 6c: Deno Integration Tests

**File:** `db1/supabase/functions/bridge-worker/index.test.ts`

These run against the live local Supabase instances (`deno test --allow-net --allow-env`).

**Tests:**

- Bridge worker returns `{ status: "idle" }` when queue is empty
- End-to-end: seed config + inventory on DB1, enqueue -> invoke worker -> verify `confirmed_tickets` row exists on DB2 and slot is `CONSUMED` on DB1
- DLQ: seed a message with `read_ct >= max_retries` -> invoke worker -> verify message in `intake_dlq` on DB1
- Webhook mode: seed config with `commit_webhook_url` pointing to a mock HTTP server → invoke worker → verify mock received the payload with correct `X-Idempotency-Key` header, slot CONSUMED on DB1

**File:** `db1/supabase/functions/admin-dlq/index.test.ts`

- List DLQ messages
- Replay: message moves from DLQ back to intake_queue
- Discard: message removed from DLQ permanently

**Acceptance:** `deno test --allow-net --allow-env db1/supabase/functions/`

---

### Phase 7: Seed Data & Final Integration

**File:** `db1/supabase/seed.sql`

```sql
INSERT INTO engine_config (pool_id, batch_size, visibility_timeout_sec, max_retries, is_active)
VALUES ('demo_concert_2026', 100, 45, 10, true);

INSERT INTO inventory_slots (pool_id, status)
SELECT 'demo_concert_2026', 'AVAILABLE'
FROM generate_series(1, 1000);
```

**File:** `db2/supabase/seed.sql`

```sql
-- Empty by default. Confirmed tickets are created by the bridge worker.
-- Uncomment below to seed sample data for dashboard testing:
-- INSERT INTO confirmed_tickets (resource_id, pool_id, user_id)
-- VALUES (gen_random_uuid(), 'demo_concert_2026', 'test_user_1');
```

---

## 7. Phase Sequencing (TDD Red-Green Cycle)

| Step | Type | Project | File | Depends On |
|------|------|---------|------|-----------|
| 0 | Scaffold | both | `db1/supabase/config.toml`, `db2/supabase/config.toml`, `.env.example` | — |
| 1 | Test (Red) | db1 | `db1/supabase/tests/00001_intake_tables.test.sql` | 0 |
| 2 | Migration (Green) | db1 | `db1/supabase/migrations/20260224100000_intake_engine_setup.sql` | 1 |
| 3a | Test (Red) | db1 | `db1/supabase/tests/00002_intake_functions.test.sql` | 2 |
| 3b | Migration (Green) | db1 | `db1/supabase/migrations/20260224100001_intake_engine_functions.sql` | 3a |
| 4a | Test (Red) | db1 | `db1/supabase/tests/00003_intake_cron.test.sql` | 3b |
| 4b | Migration (Green) | db1 | `db1/supabase/migrations/20260224100002_intake_engine_cron.sql` | 4a |
| 5a | Test (Red) | db2 | `db2/supabase/tests/00001_db2_ledger.test.sql` | 4b |
| 5b | Migration (Green) | db2 | `db2/supabase/migrations/20260224100000_db2_ledger.sql` | 5a |
| 6a | Edge Function | db1 | `db1/supabase/functions/bridge-worker/index.ts` | 5b |
| 6b | Edge Function | db1 | `db1/supabase/functions/admin-dlq/index.ts` | 5b |
| 6c | Deno Tests | db1 | `db1/supabase/functions/*/index.test.ts` | 6a, 6b |
| 7 | Seed | both | `db1/supabase/seed.sql`, `db2/supabase/seed.sql` | 5b |

---

## 8. Verification & Acceptance Criteria

1. **Local startup:** `cd db1 && supabase start` and `cd db2 && supabase start` — both boot with all extensions, run migrations
2. **pgTAP tests (DB1):** `cd db1 && supabase test db` — all 3 test files pass
3. **pgTAP tests (DB2):** `cd db2 && supabase test db` — all 1 test file passes
4. **Seed:** `cd db1 && supabase db reset` and `cd db2 && supabase db reset` — runs migrations + seed.sql
5. **Deno tests:** `deno test --allow-net --allow-env db1/supabase/functions/`
6. **Manual E2E:**
   ```bash
   # Claim a ticket (DB1)
   curl -X POST 'http://127.0.0.1:54321/rest/v1/rpc/claim_resource_and_queue' \
     -H 'apikey: <db1_anon_key>' -H 'Content-Type: application/json' \
     -d '{"p_pool_id":"demo_concert_2026","p_user_id":"user_42"}'

   # Invoke bridge worker (DB1 edge function)
   curl -X POST 'http://127.0.0.1:54321/functions/v1/bridge-worker' \
     -H 'Authorization: Bearer <db1_service_role_key>'

   # Verify ticket on DB2
   curl 'http://127.0.0.1:54421/rest/v1/confirmed_tickets?select=*' \
     -H 'apikey: <db2_service_role_key>'

   # Verify slot CONSUMED on DB1
   curl 'http://127.0.0.1:54321/rest/v1/inventory_slots?select=id,status&status=eq.CONSUMED' \
     -H 'apikey: <db1_service_role_key>'
   ```
7. **Concurrency test:** Multiple simultaneous claims — no deadlocks, correct slot count
8. **Cross-database scenarios:**
   - **Happy path:** Claim on DB1 -> bridge worker -> row appears on DB2's `confirmed_tickets`, slot CONSUMED on DB1
   - **DB2 failure:** Stop DB2, invoke bridge worker, verify messages stay on DB1 queue (not deleted). Restart DB2, invoke again, verify messages drain.
   - **Idempotency:** Same message processed twice -> only one row on DB2
   - **Webhook commit mode:** Configure `commit_webhook_url` in engine_config, run bridge worker, verify payload POSTed to webhook URL with `X-Idempotency-Key` header, slot CONSUMED on DB1
