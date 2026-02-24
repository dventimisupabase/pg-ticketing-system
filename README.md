# pg-ticketing-system

A **Burst-to-Queue Ledger** — a high-concurrency architectural pattern that absorbs massive traffic spikes, processes business logic asynchronously, and smoothly writes finalized data to any legacy or core database.

**[Live Explainer](https://dventimisupabase.github.io/pg-ticketing-system/explainer.html)**

## What

A production-ready reference implementation for surviving "thundering herd" events — ticket drops, flash sales, limited-inventory releases — without deadlocks, lost transactions, or database crashes.

The system uses two databases connected by a serverless worker bridge:

| Component | Role |
|-----------|------|
| **DB1 — Shock Absorber** | Ephemeral Postgres with `UNLOGGED` tables and `SKIP LOCKED` queries. Absorbs the burst, drops intents into a `pgmq` message queue. |
| **Bridge Worker** | Supabase Edge Function that drains the queue at a controlled rate, validates via webhooks, and commits to DB2. |
| **DB2 — Core Ledger** | Your existing database. Receives only a metered stream of finalized, validated transactions. |

## Why

100,000 users hitting the same row simultaneously causes deadlocks no matter how much you vertically scale. This pattern decouples intake from the ledger:

- **Zero contention** — `FOR UPDATE SKIP LOCKED` eliminates row-level lock wars
- **Zero migration risk** — DB2 is accessed via pluggable webhooks or RPCs; no schema rewrites
- **Zero tickets lost** — queue persistence, visibility timeouts, DLQ, and idempotency keys guarantee delivery even through downstream crashes
- **Cost efficient** — DB1 is ephemeral; spin up before the event, tear down after

## How

### Architecture

```
Users ──→ DB1 (SKIP LOCKED) ──→ pgmq ──→ Bridge Worker ──→ DB2 (Core Ledger)
              UNLOGGED tables       intake_queue    Edge Function      System of Record
```

### Slot Lifecycle

```
AVAILABLE ──→ RESERVED ──→ CONSUMED
                  │
                  └── (orphaned > 10min) ──→ AVAILABLE  (reaper cron)
```

### Message State Machine

```
queued ──→ validated ──→ committed
  │            │
  └── retry ───┘── retry (skip validation) ──→ committed
```

### Pluggable Commit Interface

The bridge worker supports two commit modes configured per pool via `engine_config`:

- **Webhook Mode** — `HTTP POST` with `X-Idempotency-Key` header to a legacy API
- **RPC Mode** — `db2.rpc('finalize_transaction')` direct to Supabase DB2

### Key Files

| File | Description |
|------|-------------|
| `gemini_docs.md` | Architecture pitch and business case |
| `PRD.md` | Full product requirements and implementation phases |
| `001_intake_engine_setup.sql` | Original DB1 migration (reference) |
| `bridge_worker.ts` | Original bridge worker (reference) |
| `explainer.html` | Interactive architecture explainer |
