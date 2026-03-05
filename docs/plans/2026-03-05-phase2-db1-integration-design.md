# Phase 2: DB1 Integration Design

**Goal:** Wire the SupaTickets webapp to use DB1 (intake engine) as the concurrency gatekeeper for ticket claiming, demonstrating the full Burst-to-Queue Ledger architecture.

**Baseline:** Phase 1 is complete — DB2 marketplace (events, tickets, cart, checkout, orders) deployed to Vercel with cloud DB2. DB1 (intake engine with sequence-based O(1) claiming, pgmq, bridge worker) deployed to cloud separately. They are not yet connected through the webapp.

---

## Architecture

DB1 is the shock absorber. DB2 is the system of record.

```
Add to Cart:   User → DB1.claim_resource_and_queue (O(1), serializes concurrent claims)
                    → DB2.claim_tickets (bookkeeping, uncontended behind DB1)

Remove/Expire: User → DB1.unclaim_slot → DB2.unclaim_tickets

Checkout:      User → DB2.checkout_cart (unchanged)

Availability:  DB2.get_event_availability (unchanged, event_tickets stays in sync)

Background:    DB1 sweep → pgmq → bridge worker → DB2.finalize_transaction
               (ledger reconciliation, not blocking user flow)
```

The bridge worker runs in the background as a durability/reconciliation layer. It does not block the user experience. In production, DB2 could be any system (SQL Server, REST API, etc.) — DB1 and the bridge worker are the universal adapter.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| UX model | Synchronous | DB1 claim is ~1ms. User gets instant feedback. Bridge worker finalizes async. |
| Cart model | DB1 claims, DB2 cart | Claim concurrency on DB1, cart/order state on DB2. Keeps existing cart UX. |
| Pool mapping | Event UUID as pool_id | 1:1 mapping, no lookup table. Webapp passes event_id directly to DB1. |
| Checkout | DB2 direct | Only "Add to Cart" goes through DB1. Checkout calls DB2's checkout_cart as-is. |
| Slot release | Explicit unclaim RPC on DB1 | New unclaim_slot function. DB1 reaper cron is the safety net. |
| DB1 auth | Pass user_id explicitly | DB1 has no auth system. Webapp authenticates via DB2 Supabase Auth, passes user.id to DB1. Future: layer in proper auth. |

## Webapp Changes

**New: DB1 Supabase client.** Two new env vars (`NEXT_PUBLIC_DB1_URL`, `NEXT_PUBLIC_DB1_ANON_KEY`). A second browser client for DB1 RPCs.

**Modified: addToCart (cart-context.tsx):**
1. Loop: call DB1 `claim_resource_and_queue(event_uuid, user_id)` once per ticket
2. If any claim returns NULL (sold out), unclaim the successful ones, return error
3. On success: call DB2 `claim_tickets(event_id, count)` to mark event_tickets RESERVED and write cart_item

**Modified: removeFromCart:**
1. Call DB1 `unclaim_slot(event_uuid, user_id)` to release slots
2. Call DB2 `unclaim_tickets(event_id)` (unchanged)

**Modified: expiry handling:**
- When client-side timer detects expired cart item, call DB1 unclaim + DB2 unclaim

**Unchanged:** checkout, availability queries, event browsing, cart display, order history.

## DB1 Changes

**New function: `unclaim_slot(p_pool_id, p_user_id)`**
- Resets RESERVED slots back to AVAILABLE for a given pool + user
- Clears locked_by, locked_at, queued_at
- Returns count of released slots
- SECURITY DEFINER (callable via PostgREST with anon key)

**No other DB1 changes.** Existing claim_resource_and_queue, sweep, bridge worker, reaper all work as-is.

## DB2 Changes

**None.** All existing functions (claim_tickets, unclaim_tickets, checkout_cart, get_event_availability, reap_expired_reservations) and tables (events, event_tickets, cart_items, orders, order_items) remain unchanged.

DB2's `claim_tickets` still uses `FOR UPDATE SKIP LOCKED`, but with DB1 as gatekeeper, contention is effectively zero.

## Slot Provisioning

For each DB2 event, DB1 needs matching inventory_slots:

1. Read event UUID and `total_tickets` from DB2
2. Insert `total_tickets` rows into DB1 `inventory_slots` with `pool_id = event_uuid`
3. Call `assign_seq_positions(event_uuid)` to set sequential positions
4. Call `reset_claim_sequence(event_uuid, 1)` to initialize the claim sequence

One-time seed operation, same pattern as the load test runner.

## Deployment

1. Apply DB1 migration (unclaim_slot) to cloud DB1
2. Run slot provisioning against cloud DB1 (matching DB2's 6 events)
3. Add `NEXT_PUBLIC_DB1_URL` and `NEXT_PUBLIC_DB1_ANON_KEY` to Vercel env vars
4. Deploy updated webapp to Vercel

## Testing

- Local: both Supabase instances running, full add-to-cart → checkout flow
- Cloud: Vercel webapp hitting cloud DB1 + cloud DB2
