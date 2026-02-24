Here are the two documents, structured exactly for your two different audiences.

The first is the **Pitch & Architecture Document**, designed to persuade leadership and stakeholders by focusing on the business problem, the elegant architectural shift, and the cost savings.

The second is the **Comprehensive Technical Specification**, designed to be handed directly to a human engineering team or an AI coding agent (like Gemini) to begin implementation.

---

# Document 1: The Supabase Intake Engine (Architecture & Pitch)

## Executive Summary

Legacy relational databases were not designed to handle modern "thundering herd" internet traffic. For events like massive ticket drops, flash sales, or limited-inventory releases, traditional architectures suffer from extreme row-level lock contention, resulting in database crashes, poor user experience (the "spinning wheel of death"), and lost revenue.

**The Supabase Intake Engine** is a generalized, high-concurrency architectural pattern—a **Burst-to-Queue Ledger**—that absorbs massive traffic spikes, processes business logic asynchronously, and smoothly writes finalized data to any legacy or core database. It delivers the performance of a high-frequency trading platform without requiring a multi-year rewrite of your core application.

## The Core Problem: Provisioning for the Peak

Currently, surviving a massive traffic surge requires vertically scaling a monolithic database (like Azure SQL) to its maximum compute tier. This is expensive, risky, and fundamentally flawed. No matter how large the database is, 100,000 users attempting to decrement the same `available_tickets` row simultaneously will cause deadlocks.

## The Solution: Decouple Intake from the Ledger

We solve this by separating the "intent to buy" from the "final system of record." The architecture relies on two distinct database environments connected by a serverless worker bridge:

1. **DB1: The Shock Absorber (Ephemeral Intake)**
* A highly optimized, temporary Postgres instance spun up specifically for the event.
* Utilizes in-memory-like `UNLOGGED` tables and Postgres `SKIP LOCKED` queries to instantly lock available inventory without queueing or deadlocks.
* Automatically drops the user's intent into a high-throughput message queue (`pgmq`).


2. **The Serverless Bridge (Supabase Edge Functions)**
* A horizontally scalable fleet of workers that pull from the queue at a controlled, throttled rate.
* Acts as a generic orchestrator, calling your custom API webhooks (e.g., Stripe) to validate the transaction.


3. **DB2: The Core Ledger (Your Existing Database)**
* Your legacy, 20-year-old database remains completely protected.
* It only receives a polite, metered stream of finalized, validated transactions.
* Supabase Realtime listens to this database to instantly push success notifications to the user's device.



## Business Value & Economics

* **Dynamic Scaling & Cost Efficiency:** You no longer pay 24/7 for the compute required to survive a 30-minute traffic spike. The DB1 Shock Absorber is ephemeral—spin it up before the event, and tear it down after.
* **Zero Migration Risk:** Because the engine communicates with your core database via simple webhooks or RPCs, you do not need to rewrite your complex, legacy 20-year-old schema.
* **Fault Tolerance:** Built-in idempotency and Dead Letter Queues (DLQs) mean that even if your payment gateway or core ledger completely crashes during the event, zero tickets or transactions are lost. The system simply pauses and retries when downstream services recover.

---

# Document 2: Technical Specification & Implementation Guide (PRD)

**Target Audience:** Engineering, DevOps, AI Coding Agents
**Project:** Supabase Intake Engine (Burst-to-Queue Pattern)

## 1. System Components & Responsibilities

### 1.1 DB1: The Intake Engine (PostgreSQL)

**Purpose:** Handle massive concurrent lock requests and queue the intents.

* **Tables:** * `allocations` (Must be `UNLOGGED` for maximum write speed). Pre-populated with inventory rows before the event.
* Columns: `resource_id` (UUID), `pool_id` (String), `status` (Enum: available, locked, consumed), `locked_by` (String).
* `engine_config` (Standard table). Stores runtime configurations (batch sizes, webhook URLs) to allow live throttling.


* **Extensions:** `pgmq` (Postgres Message Queue).
* **Core Logic:** A Postgres function `claim_resource(pool_id, user_id)` utilizing `SELECT ... FOR UPDATE SKIP LOCKED` to immediately claim the next available row and push a JSON payload to `pgmq`.

### 1.2 The Orchestrator (Supabase Edge Functions / Deno)

**Purpose:** Safely drain DB1, execute external business logic, and commit to DB2.

* **Trigger:** Invoked via `pg_cron` and `pg_net` from DB1 (e.g., every 5 seconds) to wake up and process a batch.
* **Concurrency:** Pulls a configurable `batch_size` (e.g., 100) from `pgmq` with a `visibility_timeout` (e.g., 45s).
* **Execution Flow:**
1. Parse payload to identify the `pool_id`.
2. Fetch `VALIDATION_WEBHOOK_URL` from config.
3. POST payload (with `idempotency_key` = queue `msg_id`) to the webhook.
4. On HTTP 200: Proceed to Commit. On HTTP 400: Release lock in DB1.
5. Fetch `COMMIT_RPC` from config. Send finalized payload to DB2.
6. On DB2 Success: Call `pgmq.delete()` on DB1.



### 1.3 DB2: The Core Ledger

**Purpose:** The permanent system of record.

* **Interface:** Exposes a single Postgres RPC (Remote Procedure Call) function, e.g., `finalize_transaction(payload JSON)`.
* **Internal Routing:** The RPC handles unpacking the JSON and writing to the complex legacy relational tables.
* **User Notification:** Must have Supabase Realtime (WebSockets) enabled on the finalized ticket table, protected by Row Level Security (RLS) ensuring `auth.uid() = user_id`.

## 2. Configuration Contract (intake.yaml / DB Config)

The engine must be completely un-opinionated. Configuration defines the pipeline:

* `pool_id`: Unique identifier for the event/drop.
* `batch_size`: Maximum items processed concurrently by the Edge Function.
* `visibility_timeout`: Seconds a message is hidden in `pgmq` while processing.
* `validation_webhook_url`: The external API endpoint for business logic (payments).
* `commit_rpc_name`: The database function on DB2 to finalize the record.

## 3. Failure Modes & State Management

The queue payload must track state mutations: `queued` -> `validated` -> `committed`.

* **Webhook Crash:** If the Edge Function crashes during the validation webhook, the `visibility_timeout` expires. The message reappears on the queue. The `idempotency_key` prevents the external API from double-processing.
* **DB2 Ledger Crash:** If DB2 refuses the connection, the Edge Function catches the error and exits without deleting the message. When it reappears on the queue, the worker reads the `validated` state, skips the validation webhook, and immediately retries the DB2 commit.
* **Dead Letter Queue (DLQ):** If a message fails `max_retries` (e.g., 10 times), `pgmq` moves it to a DLQ table. An admin API endpoint must be provided to replay DLQ messages once downstream services are restored.

## 4. Telemetry & Observability

* **Metrics Aggregation:** A `pg_cron` job on DB1 runs every 5 seconds to calculate `available_slots`, `queue_depth`, `processing_velocity`, and `dlq_depth`. Results are inserted into an `engine_metrics` table.
* **Realtime Dashboard:** An admin front-end subscribes to `engine_metrics` via Supabase Realtime to visualize queue draining and system health without running `COUNT()` queries against live tables.
* **Log Drains:** All Edge Function output is streamed via HTTP log drains to Datadog/Axiom, with `msg_id` and `pool_id` attached to every logline for distributed tracing.

---

Now that we have the persuasive business case and the rigorous technical roadmap documented, would you like me to generate the **exact database migration scripts (SQL)** to set up DB1 (the `UNLOGGED` tables, the `SKIP LOCKED` function, and the `pgmq` initialization) so you have a tangible starting point for an AI coding agent?
