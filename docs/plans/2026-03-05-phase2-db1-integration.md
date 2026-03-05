# Phase 2: DB1 Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Wire the SupaTickets webapp to use DB1 as the concurrency gatekeeper for ticket claiming, demonstrating the full Burst-to-Queue Ledger architecture.

**Architecture:** "Add to Cart" claims a slot on DB1 (O(1) sequence-based), then records the reservation on DB2. Remove/expire unclaims on both. Checkout stays on DB2 directly. The bridge worker runs async in the background.

**Tech Stack:** PostgreSQL (DB1 migration), pgTAP (DB1 tests), Next.js/TypeScript (webapp), Supabase JS client, Bash (provisioning script)

**Design doc:** `docs/plans/2026-03-05-phase2-db1-integration-design.md`

---

## Task 1: DB1 migration — unclaim_slot + claim fixes for UUID pool_ids

**Files:**
- Create: `db1/supabase/migrations/20260305200001_unclaim_and_uuid_pool_ids.sql`

**Context:** DB1's `claim_resource_and_queue` uses `nextval('claim_seq_' || p_pool_id)` which breaks when pool_id contains hyphens (like UUIDs). Also, when users unclaim tickets, the sequence position is "burned" — the slot goes back to AVAILABLE but no future sequence position will reference it. We add a SKIP LOCKED fallback to reclaim these orphaned slots. Finally, we need an `unclaim_slot` function so the webapp can release slots explicitly.

**Step 1:** Write the migration file.

```sql
-- db1/supabase/migrations/20260305200001_unclaim_and_uuid_pool_ids.sql
-- Phase 2: Support UUID pool_ids (hyphens), add unclaim, add SKIP LOCKED fallback.

-- (a) unclaim_slot: release all RESERVED slots for a user in a pool
CREATE OR REPLACE FUNCTION unclaim_slot(
    p_pool_id TEXT,
    p_user_id TEXT
) RETURNS INT AS $$
DECLARE
    v_count INT;
BEGIN
    UPDATE inventory_slots
    SET status    = 'AVAILABLE',
        locked_by = NULL,
        locked_at = NULL,
        queued_at = NULL
    WHERE pool_id   = p_pool_id
      AND locked_by = p_user_id
      AND status    = 'RESERVED';

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- (b) Fix claim_resource_and_queue: quote sequence name for UUID pool_ids,
--     add SKIP LOCKED fallback for recycled slots
CREATE OR REPLACE FUNCTION claim_resource_and_queue(
    p_pool_id TEXT,
    p_user_id TEXT
) RETURNS UUID AS $$
DECLARE
    pos BIGINT;
    claimed_slot_id UUID;
BEGIN
    -- O(1): atomically grab next position (format %I handles hyphens in pool_id)
    pos := nextval(format('%I', 'claim_seq_' || p_pool_id));

    -- Direct index lookup on (pool_id, seq_pos); HOT-eligible update
    UPDATE inventory_slots
    SET status    = 'RESERVED',
        locked_by = p_user_id,
        locked_at = NOW()
    WHERE pool_id = p_pool_id
      AND seq_pos = pos
    RETURNING id INTO claimed_slot_id;

    -- Fallback: sequence advanced past all slots (burned positions from unclaims).
    -- Try any AVAILABLE slot via SKIP LOCKED.
    IF claimed_slot_id IS NULL THEN
        UPDATE inventory_slots
        SET status    = 'RESERVED',
            locked_by = p_user_id,
            locked_at = NOW()
        WHERE id = (
            SELECT id FROM inventory_slots
            WHERE pool_id = p_pool_id
              AND status  = 'AVAILABLE'
            LIMIT 1
            FOR UPDATE SKIP LOCKED
        )
        RETURNING id INTO claimed_slot_id;
    END IF;

    RETURN claimed_slot_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- (c) Fix reset_claim_sequence: already uses format(%I), but also fix
--     nextval reference in any future callers by ensuring the sequence
--     name is consistently quoted
CREATE OR REPLACE FUNCTION reset_claim_sequence(
    p_pool_id TEXT,
    p_start BIGINT DEFAULT 1
) RETURNS VOID AS $$
BEGIN
    EXECUTE format(
        'CREATE SEQUENCE IF NOT EXISTS %I START %s',
        'claim_seq_' || p_pool_id, p_start
    );
    EXECUTE format(
        'ALTER SEQUENCE %I RESTART WITH %s',
        'claim_seq_' || p_pool_id, p_start
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2:** Apply locally and verify migrations apply:

```bash
cd db1 && supabase db reset
```

Expected: migrations apply without errors.

**Step 3:** Commit:

```bash
git add db1/supabase/migrations/20260305200001_unclaim_and_uuid_pool_ids.sql
git commit -m "feat(db1): add unclaim_slot, fix UUID pool_ids, add SKIP LOCKED fallback"
```

---

## Task 2: DB1 pgTAP tests for unclaim_slot and fallback

**Files:**
- Modify: `db1/supabase/tests/00002_intake_functions.test.sql`

**Context:** The existing test file has 13 tests. We need to add tests for:
1. `unclaim_slot` releases a claimed slot back to AVAILABLE
2. `unclaim_slot` returns 0 when no slots to unclaim
3. The SKIP LOCKED fallback works after unclaim (claim a slot, unclaim it, burn the sequence past total slots, claim again → gets the recycled slot)

**Step 1:** Update the test file. Change `plan(13)` to `plan(17)` and add 4 new tests after the existing "claim returns NULL when sold out" test (line 64):

After line 64 (`'claim returns NULL when sold out'`), add:

```sql
-- unclaim_slot releases slots back to AVAILABLE
SELECT is(
    unclaim_slot('test_pool', 'user_1'),
    1,
    'unclaim_slot returns count of released slots'
);

SELECT is(
    (SELECT status FROM inventory_slots WHERE locked_by IS NULL AND seq_pos = 1 LIMIT 1),
    'AVAILABLE'::slot_status,
    'unclaimed slot status is AVAILABLE'
);

-- unclaim_slot returns 0 when nothing to unclaim
SELECT is(
    unclaim_slot('test_pool', 'user_nonexistent'),
    0,
    'unclaim_slot returns 0 when no slots to unclaim'
);

-- SKIP LOCKED fallback: sequence is past all 5 slots, but slot 1 is AVAILABLE
-- (unclaimed above). The next claim should fall back to SKIP LOCKED and find it.
SELECT isnt(
    claim_resource_and_queue('test_pool', 'user_fallback'),
    NULL,
    'claim fallback finds recycled slot via SKIP LOCKED'
);
```

**Step 2:** Run tests:

```bash
cd db1 && supabase db reset && supabase test db
```

Expected: all 17 tests pass (was 13, added 4).

**Step 3:** Commit:

```bash
git add db1/supabase/tests/00002_intake_functions.test.sql
git commit -m "test(db1): add unclaim_slot and SKIP LOCKED fallback tests"
```

---

## Task 3: Webapp — DB1 Supabase client + env vars

**Files:**
- Create: `demo/src/lib/supabase/db1-client.ts`
- Modify: `demo/.env.local.example`

**Context:** The webapp needs a second Supabase browser client for DB1. DB1 has no auth — the webapp authenticates users via DB2's Supabase Auth and passes user.id as a parameter to DB1 RPCs. The DB1 client uses the anon key (public, browser-safe).

**Step 1:** Create the DB1 browser client.

```typescript
// demo/src/lib/supabase/db1-client.ts
import { createBrowserClient } from '@supabase/ssr'

export function createDb1Client() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_DB1_URL!,
    process.env.NEXT_PUBLIC_DB1_ANON_KEY!
  )
}
```

**Step 2:** Update `.env.local.example` — add DB1 env vars:

```
# Supabase DB2 connection (marketplace database)
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54441
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0

# Supabase DB1 connection (intake engine — concurrency gatekeeper)
NEXT_PUBLIC_DB1_URL=http://127.0.0.1:54341
NEXT_PUBLIC_DB1_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0
```

Note: local dev uses the same anon key for both DBs (shared JWT secret in local Supabase).

**Step 3:** Create local `.env.local` (not committed) with the same values for local testing:

```bash
cp demo/.env.local.example demo/.env.local
```

**Step 4:** Verify the build still works:

```bash
cd demo && npm run build
```

Expected: build succeeds (the new client file is created but not yet imported).

**Step 5:** Commit:

```bash
git add demo/src/lib/supabase/db1-client.ts demo/.env.local.example
git commit -m "feat(demo): add DB1 Supabase client and env vars"
```

---

## Task 4: Webapp — integrate DB1 into cart-context

**Files:**
- Modify: `demo/src/lib/cart-context.tsx`

**Context:** The `addToCart` function currently calls DB2's `claim_tickets` RPC directly. We need to insert DB1 claiming as the first step: claim on DB1 (concurrency gate), then claim on DB2 (bookkeeping). Similarly, `removeFromCart` and the expiry handler need to unclaim on DB1 before unclaiming on DB2.

**Step 1:** Modify `demo/src/lib/cart-context.tsx`:

Add DB1 client import at the top (after existing imports):

```typescript
import { createDb1Client } from '@/lib/supabase/db1-client'
```

Inside `CartProvider`, add the DB1 client alongside the existing DB2 client:

```typescript
const db1 = createDb1Client()
```

Replace the `addToCart` function (lines 71-82) with:

```typescript
const addToCart = async (eventId: string, count: number) => {
  // Get user from DB2 auth
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return { success: false, error: 'Not authenticated' }

  // Step 1: Claim slots on DB1 (concurrency gatekeeper)
  const claimedSlots: string[] = []
  for (let i = 0; i < count; i++) {
    const { data, error } = await db1.rpc('claim_resource_and_queue', {
      p_pool_id: eventId,
      p_user_id: user.id,
    })
    if (error) {
      // Rollback: unclaim any already-claimed slots on DB1
      if (claimedSlots.length > 0) {
        await db1.rpc('unclaim_slot', { p_pool_id: eventId, p_user_id: user.id })
      }
      return { success: false, error: error.message }
    }
    if (!data) {
      // Sold out — unclaim any partial claims on DB1
      if (claimedSlots.length > 0) {
        await db1.rpc('unclaim_slot', { p_pool_id: eventId, p_user_id: user.id })
      }
      return { success: false, error: 'Not enough tickets available' }
    }
    claimedSlots.push(data)
  }

  // Step 2: Record reservation on DB2 (bookkeeping)
  const { data, error } = await supabase.rpc('claim_tickets', {
    p_event_id: eventId,
    p_count: count,
  })

  if (error || !data) {
    // DB2 claim failed — rollback DB1
    await db1.rpc('unclaim_slot', { p_pool_id: eventId, p_user_id: user.id })
    return { success: false, error: error?.message ?? 'Failed to reserve tickets' }
  }

  await refresh()
  return { success: true }
}
```

Replace the `removeFromCart` function (lines 84-87) with:

```typescript
const removeFromCart = async (eventId: string) => {
  const { data: { user } } = await supabase.auth.getUser()
  // Unclaim on DB1 first
  if (user) {
    await db1.rpc('unclaim_slot', { p_pool_id: eventId, p_user_id: user.id })
  }
  // Unclaim on DB2
  await supabase.rpc('unclaim_tickets', { p_event_id: eventId })
  await refresh()
}
```

Update the expiry handler (lines 52-65) — add DB1 unclaim before DB2 unclaim:

```typescript
useEffect(() => {
  const interval = setInterval(async () => {
    const now = new Date()
    const expired = items.filter(item => new Date(item.expires_at) <= now)
    if (expired.length > 0) {
      const { data: { user } } = await supabase.auth.getUser()
      for (const item of expired) {
        if (user) {
          await db1.rpc('unclaim_slot', { p_pool_id: item.event_id, p_user_id: user.id })
        }
        await supabase.rpc('unclaim_tickets', { p_event_id: item.event_id })
      }
      refresh()
    }
  }, 1000)

  return () => clearInterval(interval)
}, [items, supabase, db1, refresh])
```

**Step 2:** Verify build:

```bash
cd demo && npm run build
```

Expected: build succeeds.

**Step 3:** Commit:

```bash
git add demo/src/lib/cart-context.tsx
git commit -m "feat(demo): integrate DB1 claiming into cart flow"
```

---

## Task 5: DB1 slot provisioning script

**Files:**
- Create: `scripts/provision-db1-slots.sh`

**Context:** DB1 needs inventory_slots matching DB2's events. For each of the 6 seeded events, we insert `total_tickets` slots with `pool_id = event_uuid`, assign sequential positions, and reset the claim sequence. This script runs against the cloud DB1 and reads event data from cloud DB2.

**Step 1:** Write the provisioning script.

```bash
#!/usr/bin/env bash
# scripts/provision-db1-slots.sh
# Provision DB1 inventory_slots for each DB2 event.
# Usage: ./scripts/provision-db1-slots.sh
#
# Reads event UUIDs and ticket counts from DB2, then creates matching
# inventory_slots on DB1 with sequential positions and claim sequences.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.cloud"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${DB1_URL:?DB1_URL must be set}"
: "${DB1_KEY:?DB1_KEY must be set}"
: "${DB2_URL:?DB2_URL must be set}"
: "${DB2_KEY:?DB2_KEY must be set}"

db1_post() {
  curl -sf -X POST "$DB1_URL/rest/v1/$1" \
    -H "apikey: $DB1_KEY" -H "Authorization: Bearer $DB1_KEY" \
    -H "Content-Type: application/json" -H "Prefer: $2" -d "$3"
}

db1_delete() {
  curl -sf -X DELETE "$DB1_URL/rest/v1/$1" \
    -H "apikey: $DB1_KEY" -H "Authorization: Bearer $DB1_KEY"
}

echo "=== Provisioning DB1 slots for DB2 events ==="

# Fetch events from DB2
EVENTS=$(curl -sf "$DB2_URL/rest/v1/events?select=id,name,total_tickets" \
  -H "apikey: $DB2_KEY" -H "Authorization: Bearer $DB2_KEY")

echo "$EVENTS" | python3 -c "
import sys, json
events = json.load(sys.stdin)
for e in events:
    print(f\"  {e['name']}: {e['total_tickets']} tickets (pool_id={e['id']})\")"

# Process each event
echo "$EVENTS" | python3 -c "
import sys, json
events = json.load(sys.stdin)
for e in events:
    print(f\"{e['id']} {e['total_tickets']}\")
" | while read -r EVENT_ID TOTAL_TICKETS; do
  echo ""
  echo "--- $EVENT_ID ($TOTAL_TICKETS tickets) ---"

  # Ensure engine_config exists for this pool
  db1_post "engine_config" "resolution=ignore-duplicates" \
    "{\"pool_id\":\"$EVENT_ID\",\"batch_size\":100,\"visibility_timeout_sec\":45,\"max_retries\":10,\"is_active\":true}" > /dev/null

  # Delete existing slots for this pool (idempotent)
  db1_delete "inventory_slots?pool_id=eq.$EVENT_ID" > /dev/null 2>&1 || true

  # Insert slots in batches of 10,000
  REMAINING=$TOTAL_TICKETS
  INSERTED=0
  while [ "$REMAINING" -gt 0 ]; do
    BATCH_SIZE=$((REMAINING > 10000 ? 10000 : REMAINING))
    BATCH=$(python3 -c "import json; print(json.dumps([{'pool_id':'$EVENT_ID','status':'AVAILABLE'}]*$BATCH_SIZE))")
    db1_post "inventory_slots" "return=minimal" "$BATCH" > /dev/null
    INSERTED=$((INSERTED + BATCH_SIZE))
    REMAINING=$((REMAINING - BATCH_SIZE))
    printf "    Inserted %d/%d\r" "$INSERTED" "$TOTAL_TICKETS"
  done
  echo ""

  # Assign sequential positions
  echo "    Assigning sequential positions..."
  db1_post "rpc/assign_seq_positions" "return=representation" \
    "{\"p_pool_id\":\"$EVENT_ID\"}" > /dev/null

  # Reset claim sequence
  echo "    Resetting claim sequence..."
  db1_post "rpc/reset_claim_sequence" "return=minimal" \
    "{\"p_pool_id\":\"$EVENT_ID\",\"p_start\":1}" > /dev/null

  echo "    Done."
done

echo ""
echo "=== Provisioning complete ==="
```

**Step 2:** Make executable and verify syntax:

```bash
chmod +x scripts/provision-db1-slots.sh
bash -n scripts/provision-db1-slots.sh && echo "Syntax OK"
```

**Step 3:** Commit:

```bash
git add scripts/provision-db1-slots.sh
git commit -m "feat: add DB1 slot provisioning script for DB2 events"
```

---

## Task 6: Deploy to cloud

**Context:** Apply DB1 migration, provision slots, configure Vercel, and deploy the updated webapp.

**Step 1:** Apply DB1 migration to cloud:

```bash
cd db1 && supabase db push
```

Expected: migration `20260305200001_unclaim_and_uuid_pool_ids.sql` applied.

**Step 2:** Get DB1 cloud anon key:

```bash
cd db1 && supabase projects api-keys --project-ref mrhnchxesrdbecmqcigw
```

Save the `anon` key — this is `NEXT_PUBLIC_DB1_ANON_KEY`.

**Step 3:** Run the provisioning script:

```bash
./scripts/provision-db1-slots.sh
```

Expected: 6 events provisioned with matching slot counts (200 to 50,000).

**Step 4:** Set Vercel env vars:

```bash
cd demo
vercel env add NEXT_PUBLIC_DB1_URL        # value: https://mrhnchxesrdbecmqcigw.supabase.co
vercel env add NEXT_PUBLIC_DB1_ANON_KEY   # value: <anon key from step 2>
```

**Step 5:** Deploy:

```bash
cd demo && vercel --prod
```

**Step 6:** Test the full flow on production:
1. Browse events at `https://demo-liart-three-47.vercel.app`
2. Sign in
3. Add tickets to cart (should claim via DB1 → record on DB2)
4. Verify cart shows items with countdown
5. Remove an item (should unclaim on DB1 + DB2)
6. Add again + checkout (should create order on DB2)
7. Verify order in Account page

**Step 7:** Commit and push all changes:

```bash
git push
```

---

## Files touched

| File | Action |
|------|--------|
| `db1/supabase/migrations/20260305200001_unclaim_and_uuid_pool_ids.sql` | Create |
| `db1/supabase/tests/00002_intake_functions.test.sql` | Modify |
| `demo/src/lib/supabase/db1-client.ts` | Create |
| `demo/.env.local.example` | Modify |
| `demo/src/lib/cart-context.tsx` | Modify |
| `scripts/provision-db1-slots.sh` | Create |

## Verification

1. `cd db1 && supabase db reset` — migrations apply cleanly
2. `cd db1 && supabase test db` — all tests pass (17, up from 13)
3. `cd demo && npm run build` — webapp builds
4. Local manual test: add to cart → verify DB1 slot claimed → checkout → verify order
5. Cloud: full flow on Vercel production URL
