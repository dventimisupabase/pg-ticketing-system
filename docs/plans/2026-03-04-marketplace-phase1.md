# Ticket Marketplace — Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a standalone ticket marketplace on DB2 (Supabase) with a Next.js frontend on Vercel — the "legacy" app that later gets a DB1 shield bolted on.

**Architecture:** Next.js App Router → Supabase DB2 (PostgreSQL 17). Events catalog, individual ticket inventory with row-level reservations, shopping cart with 20-minute timers, simple checkout. Supabase Auth for user sessions. pg_cron reaper for expired reservations.

**Tech Stack:** Next.js 15, TypeScript, Tailwind CSS, @supabase/ssr, @supabase/auth-ui-react, PostgreSQL 17, pgTAP, Vercel

**Design doc:** `docs/plans/2026-03-04-ticket-marketplace-design.md`

---

## Task 1: DB2 marketplace schema migration

**Files:**
- Create: `db2/supabase/migrations/20260304200000_marketplace_schema.sql`

**Step 1: Write the migration**

```sql
-- db2/supabase/migrations/20260304200000_marketplace_schema.sql
-- Marketplace tables: events, tickets, cart, orders.

-- Ticket status enum
CREATE TYPE ticket_status AS ENUM ('AVAILABLE', 'RESERVED', 'SOLD');

-- Events catalog
CREATE TABLE events (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT NOT NULL,
    description  TEXT,
    date         TIMESTAMPTZ NOT NULL,
    venue        TEXT NOT NULL,
    location     TEXT NOT NULL,
    image_url    TEXT,
    ticket_price NUMERIC(10,2) NOT NULL,
    total_tickets INT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Individual ticket inventory (one row per ticket)
CREATE TABLE event_tickets (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id    UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    status      ticket_status NOT NULL DEFAULT 'AVAILABLE',
    reserved_by UUID REFERENCES auth.users(id),
    reserved_at TIMESTAMPTZ,
    seq_pos     INT
);

-- Index for claim queries: find AVAILABLE tickets by event
CREATE INDEX idx_event_tickets_available
    ON event_tickets (event_id, status)
    WHERE status = 'AVAILABLE';

-- Index for reaper: find expired reservations
CREATE INDEX idx_event_tickets_reserved
    ON event_tickets (reserved_at)
    WHERE status = 'RESERVED';

-- Shopping cart
CREATE TABLE cart_items (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    event_id     UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    ticket_count INT NOT NULL CHECK (ticket_count > 0),
    expires_at   TIMESTAMPTZ NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, event_id)  -- one cart entry per event per user
);

-- Orders (completed purchases)
CREATE TABLE orders (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES auth.users(id),
    total_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Order line items
CREATE TABLE order_items (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id     UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    event_id     UUID NOT NULL REFERENCES events(id),
    ticket_count INT NOT NULL,
    unit_price   NUMERIC(10,2) NOT NULL
);

-- === RLS ===

-- Events: public read
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "events are publicly readable"
    ON events FOR SELECT USING (true);

-- Event tickets: public read (for availability counts)
ALTER TABLE event_tickets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "tickets are publicly readable"
    ON event_tickets FOR SELECT USING (true);

-- Cart items: users see/manage only their own
ALTER TABLE cart_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users manage own cart"
    ON cart_items FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- Orders: users see only their own
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users view own orders"
    ON orders FOR SELECT
    USING (auth.uid() = user_id);

-- Order items: users see only items in their orders
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "users view own order items"
    ON order_items FOR SELECT
    USING (order_id IN (SELECT id FROM orders WHERE user_id = auth.uid()));
```

**Step 2: Apply migration locally**

```bash
cd db2 && supabase db reset
```

Expected: migrations apply without errors.

**Step 3: Commit**

```bash
git add db2/supabase/migrations/20260304200000_marketplace_schema.sql
git commit -m "feat(db2): add marketplace schema (events, tickets, cart, orders)"
```

---

## Task 2: DB2 marketplace functions

**Files:**
- Create: `db2/supabase/migrations/20260304200001_marketplace_functions.sql`

**Step 1: Write the migration**

```sql
-- db2/supabase/migrations/20260304200001_marketplace_functions.sql
-- Marketplace RPC functions: claim, unclaim, checkout, availability, reaper.

-- claim_tickets: all-or-nothing batch claim
-- Returns array of ticket IDs on success, NULL if insufficient inventory.
CREATE OR REPLACE FUNCTION claim_tickets(
    p_event_id UUID,
    p_count    INT
) RETURNS UUID[] AS $$
DECLARE
    v_user_id  UUID := auth.uid();
    v_claimed  UUID[];
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'authentication required';
    END IF;

    -- Lock and select p_count AVAILABLE tickets
    SELECT ARRAY_AGG(id) INTO v_claimed
    FROM (
        SELECT id FROM event_tickets
        WHERE event_id = p_event_id AND status = 'AVAILABLE'
        ORDER BY seq_pos
        FOR UPDATE SKIP LOCKED
        LIMIT p_count
    ) sub;

    -- All-or-nothing: if fewer than requested, return NULL
    IF v_claimed IS NULL OR array_length(v_claimed, 1) < p_count THEN
        RETURN NULL;
    END IF;

    -- Reserve the tickets
    UPDATE event_tickets
    SET status      = 'RESERVED',
        reserved_by = v_user_id,
        reserved_at = NOW()
    WHERE id = ANY(v_claimed);

    -- Insert cart item (upsert: if user already has this event, update count)
    INSERT INTO cart_items (user_id, event_id, ticket_count, expires_at)
    VALUES (v_user_id, p_event_id, p_count, NOW() + INTERVAL '20 minutes')
    ON CONFLICT (user_id, event_id) DO UPDATE
    SET ticket_count = cart_items.ticket_count + EXCLUDED.ticket_count,
        expires_at   = NOW() + INTERVAL '20 minutes';

    RETURN v_claimed;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- unclaim_tickets: release reserved tickets for a user+event
-- Returns count of released tickets.
CREATE OR REPLACE FUNCTION unclaim_tickets(
    p_event_id UUID
) RETURNS INT AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_count   INT;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'authentication required';
    END IF;

    UPDATE event_tickets
    SET status      = 'AVAILABLE',
        reserved_by = NULL,
        reserved_at = NULL
    WHERE event_id    = p_event_id
      AND reserved_by = v_user_id
      AND status      = 'RESERVED';

    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- Remove cart item
    DELETE FROM cart_items
    WHERE user_id = v_user_id AND event_id = p_event_id;

    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- checkout_cart: create order from non-expired cart items
-- Returns order ID on success, NULL if cart is empty/expired.
CREATE OR REPLACE FUNCTION checkout_cart()
RETURNS UUID AS $$
DECLARE
    v_user_id  UUID := auth.uid();
    v_order_id UUID;
    v_total    NUMERIC(10,2) := 0;
    v_item     RECORD;
    v_has_items BOOLEAN := FALSE;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'authentication required';
    END IF;

    -- Create order
    INSERT INTO orders (user_id, total_amount)
    VALUES (v_user_id, 0)
    RETURNING id INTO v_order_id;

    -- Process each non-expired cart item
    FOR v_item IN
        SELECT ci.id AS cart_item_id, ci.event_id, ci.ticket_count, e.ticket_price
        FROM cart_items ci
        JOIN events e ON e.id = ci.event_id
        WHERE ci.user_id = v_user_id
          AND ci.expires_at > NOW()
    LOOP
        v_has_items := TRUE;

        -- Create order line item
        INSERT INTO order_items (order_id, event_id, ticket_count, unit_price)
        VALUES (v_order_id, v_item.event_id, v_item.ticket_count, v_item.ticket_price);

        -- Mark tickets as SOLD
        UPDATE event_tickets
        SET status = 'SOLD'
        WHERE event_id    = v_item.event_id
          AND reserved_by = v_user_id
          AND status      = 'RESERVED';

        v_total := v_total + (v_item.ticket_count * v_item.ticket_price);
    END LOOP;

    -- Update order total
    UPDATE orders SET total_amount = v_total WHERE id = v_order_id;

    -- Clear cart
    DELETE FROM cart_items WHERE user_id = v_user_id;

    -- If no valid items, delete the empty order
    IF NOT v_has_items THEN
        DELETE FROM orders WHERE id = v_order_id;
        RETURN NULL;
    END IF;

    RETURN v_order_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- get_event_availability: count AVAILABLE tickets for an event
CREATE OR REPLACE FUNCTION get_event_availability(p_event_id UUID)
RETURNS INT AS $$
    SELECT COUNT(*)::INT FROM event_tickets
    WHERE event_id = p_event_id AND status = 'AVAILABLE';
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- reap_expired_reservations: release tickets reserved > 20 minutes ago
-- Called by pg_cron every minute.
CREATE OR REPLACE FUNCTION reap_expired_reservations()
RETURNS INT AS $$
DECLARE
    v_count INT;
BEGIN
    -- Release expired tickets
    UPDATE event_tickets
    SET status      = 'AVAILABLE',
        reserved_by = NULL,
        reserved_at = NULL
    WHERE status = 'RESERVED'
      AND reserved_at < NOW() - INTERVAL '20 minutes';

    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- Clean up expired cart items
    DELETE FROM cart_items WHERE expires_at <= NOW();

    RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

**Step 2: Apply migration locally**

```bash
cd db2 && supabase db reset
```

Expected: migrations apply without errors.

**Step 3: Commit**

```bash
git add db2/supabase/migrations/20260304200001_marketplace_functions.sql
git commit -m "feat(db2): add marketplace functions (claim, unclaim, checkout, reaper)"
```

---

## Task 3: DB2 pgTAP tests

**Files:**
- Create: `db2/supabase/tests/00002_marketplace.test.sql`

The test authenticates as a fake user via `set_config('request.jwt.claims', ...)` so `auth.uid()` works inside SECURITY DEFINER functions.

**Step 1: Write the tests**

```sql
-- db2/supabase/tests/00002_marketplace.test.sql
BEGIN;
SELECT plan(20);

-- === Schema tests ===

SELECT has_table('events', 'events table exists');
SELECT has_table('event_tickets', 'event_tickets table exists');
SELECT has_table('cart_items', 'cart_items table exists');
SELECT has_table('orders', 'orders table exists');
SELECT has_table('order_items', 'order_items table exists');

-- === Function tests ===

SELECT has_function('claim_tickets', 'claim_tickets function exists');
SELECT has_function('unclaim_tickets', 'unclaim_tickets function exists');
SELECT has_function('checkout_cart', 'checkout_cart function exists');
SELECT has_function('get_event_availability', 'get_event_availability function exists');
SELECT has_function('reap_expired_reservations', 'reap_expired_reservations function exists');

-- === Seed test data ===

-- Create a test user in auth.users
INSERT INTO auth.users (id, email, encrypted_password, email_confirmed_at, role, aud, instance_id)
VALUES (
    'a0000000-0000-0000-0000-000000000001'::uuid,
    'test@example.com',
    crypt('password', gen_salt('bf')),
    now(),
    'authenticated',
    'authenticated',
    '00000000-0000-0000-0000-000000000000'::uuid
);

-- Set auth context to test user
SELECT set_config('request.jwt.claims',
    '{"sub":"a0000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
SELECT set_config('role', 'authenticated', true);

-- Create a test event
INSERT INTO events (id, name, description, date, venue, location, ticket_price, total_tickets)
VALUES (
    'e0000000-0000-0000-0000-000000000001'::uuid,
    'Test Concert',
    'A test event',
    '2026-07-01'::timestamptz,
    'Test Arena',
    'Test City',
    50.00,
    5
);

-- Create 5 tickets
INSERT INTO event_tickets (event_id, seq_pos)
SELECT 'e0000000-0000-0000-0000-000000000001'::uuid, generate_series(1, 5);

-- === get_event_availability ===

SELECT is(
    get_event_availability('e0000000-0000-0000-0000-000000000001'::uuid),
    5,
    'get_event_availability returns 5 for 5 available tickets'
);

-- === claim_tickets: success ===

SELECT is(
    array_length(claim_tickets('e0000000-0000-0000-0000-000000000001'::uuid, 2), 1),
    2,
    'claim_tickets returns 2 UUIDs when claiming 2 tickets'
);

SELECT is(
    get_event_availability('e0000000-0000-0000-0000-000000000001'::uuid),
    3,
    'availability decreases to 3 after claiming 2'
);

-- Verify cart item was created
SELECT is(
    (SELECT ticket_count FROM cart_items
     WHERE user_id = 'a0000000-0000-0000-0000-000000000001'::uuid
       AND event_id = 'e0000000-0000-0000-0000-000000000001'::uuid),
    2,
    'cart_items entry created with ticket_count=2'
);

-- === claim_tickets: all-or-nothing (request 4, only 3 available) ===

SELECT is(
    claim_tickets('e0000000-0000-0000-0000-000000000001'::uuid, 4),
    NULL::uuid[],
    'claim_tickets returns NULL when requesting more than available (all-or-nothing)'
);

-- === unclaim_tickets ===

SELECT is(
    unclaim_tickets('e0000000-0000-0000-0000-000000000001'::uuid),
    2,
    'unclaim_tickets releases 2 tickets'
);

SELECT is(
    get_event_availability('e0000000-0000-0000-0000-000000000001'::uuid),
    5,
    'availability returns to 5 after unclaim'
);

-- === checkout_cart ===

-- Claim 1 ticket, then checkout
SELECT claim_tickets('e0000000-0000-0000-0000-000000000001'::uuid, 1);

SELECT isnt(
    checkout_cart(),
    NULL::uuid,
    'checkout_cart returns a non-NULL order ID'
);

SELECT is(
    get_event_availability('e0000000-0000-0000-0000-000000000001'::uuid),
    4,
    'availability is 4 after checkout (1 ticket SOLD)'
);

-- Verify order was created
SELECT is(
    (SELECT total_amount FROM orders
     WHERE user_id = 'a0000000-0000-0000-0000-000000000001'::uuid
     ORDER BY created_at DESC LIMIT 1),
    50.00::numeric(10,2),
    'order total_amount is 50.00 (1 ticket * $50)'
);

SELECT finish();
ROLLBACK;
```

**Step 2: Run tests**

```bash
cd db2 && supabase db reset && supabase test db
```

Expected: all 28 tests pass (8 existing + 20 new). Adjust plan count if actual output differs.

**Step 3: Commit**

```bash
git add db2/supabase/tests/00002_marketplace.test.sql
git commit -m "test(db2): add pgTAP tests for marketplace schema and functions"
```

---

## Task 4: DB2 seed data + pg_cron reaper

**Files:**
- Modify: `db2/supabase/seed.sql`
- Create: `db2/supabase/migrations/20260304200002_marketplace_cron.sql`

**Step 1: Write the seed file**

```sql
-- db2/supabase/seed.sql
-- Seed 6 events with ticket inventory for the marketplace demo.

INSERT INTO events (id, name, description, date, venue, location, image_url, ticket_price, total_tickets) VALUES
('e1000000-0000-0000-0000-000000000001', 'Kendrick Lamar — Grand Final Tour',
 'The Pulitzer Prize-winning artist brings his legendary catalog to the stage for one last time.',
 '2026-07-15 20:00:00-07', 'Allegiant Stadium', 'Las Vegas, NV',
 'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?w=800&h=400&fit=crop',
 150.00, 50000),

('e2000000-0000-0000-0000-000000000002', 'Royal Shakespeare Company — Hamlet',
 'A bold new production of Shakespeare''s greatest tragedy, featuring an all-star ensemble cast.',
 '2026-05-20 19:30:00+01', 'Barbican Theatre', 'London, UK',
 'https://images.unsplash.com/photo-1503095396549-807759245b35?w=800&h=400&fit=crop',
 85.00, 800),

('e3000000-0000-0000-0000-000000000003', 'Taylor Swift — Eras Tour II',
 'She''s back. The biggest tour in history returns with new music, new production, new era.',
 '2026-09-01 19:00:00-07', 'SoFi Stadium', 'Los Angeles, CA',
 'https://images.unsplash.com/photo-1501386761578-eac5c94b800a?w=800&h=400&fit=crop',
 250.00, 20000),

('e4000000-0000-0000-0000-000000000004', 'Friday Night Jazz Quartet',
 'An intimate evening of classic jazz standards and original compositions.',
 '2026-04-18 21:00:00-04', 'Blue Note', 'New York, NY',
 'https://images.unsplash.com/photo-1511192336575-5a79af67a629?w=800&h=400&fit=crop',
 35.00, 200),

('e5000000-0000-0000-0000-000000000005', 'NBA Finals — Game 7',
 'The ultimate showdown. Two teams, one trophy, winner takes all.',
 '2026-06-22 18:00:00-07', 'Chase Center', 'San Francisco, CA',
 'https://images.unsplash.com/photo-1546519638-68e109498ffc?w=800&h=400&fit=crop',
 300.00, 18000),

('e6000000-0000-0000-0000-000000000006', 'Cirque du Soleil — Ethereal',
 'A breathtaking new spectacle blending acrobatics, dance, and immersive technology.',
 '2026-08-10 19:30:00+01', 'Royal Albert Hall', 'London, UK',
 'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=800&h=400&fit=crop',
 120.00, 2500);

-- Generate ticket inventory for each event.
-- Uses generate_series to create one row per ticket.
INSERT INTO event_tickets (event_id, seq_pos)
SELECT e.id, gs.n
FROM events e
CROSS JOIN LATERAL generate_series(1, e.total_tickets) AS gs(n);
```

**Step 2: Write the pg_cron migration**

```sql
-- db2/supabase/migrations/20260304200002_marketplace_cron.sql
-- pg_cron job: reap expired reservations every minute.

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

SELECT cron.schedule(
    'reap-expired-reservations',
    '* * * * *',
    $$SELECT reap_expired_reservations()$$
);
```

**Step 3: Reset and verify**

```bash
cd db2 && supabase db reset
```

Expected: migrations apply, seed runs (creates 6 events + ~91,500 tickets). Verify:

```bash
cd db2 && supabase test db
```

Expected: all tests pass.

**Step 4: Commit**

```bash
git add db2/supabase/seed.sql db2/supabase/migrations/20260304200002_marketplace_cron.sql
git commit -m "feat(db2): add marketplace seed data (6 events) and reaper cron job"
```

---

## Task 5: Next.js app scaffold

**Files:**
- Create: `demo/` directory (Next.js app)

**Step 1: Create the Next.js app**

```bash
cd /Users/davida.ventimiglia/Work/pg-ticketing-system
npx create-next-app@latest demo --typescript --tailwind --eslint --app --src-dir --no-import-alias --use-npm
```

Accept defaults. This creates `demo/` with App Router, TypeScript, Tailwind.

**Step 2: Install Supabase dependencies**

```bash
cd demo && npm install @supabase/supabase-js @supabase/ssr @supabase/auth-ui-react @supabase/auth-ui-shared
```

**Step 3: Create environment template**

Create `demo/.env.local.example`:

```bash
# Supabase DB2 connection (marketplace database)
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54441
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0
```

Copy it for local dev:

```bash
cp demo/.env.local.example demo/.env.local
```

**Step 4: Commit**

```bash
git add demo/
git commit -m "feat(demo): scaffold Next.js app with Supabase dependencies"
```

---

## Task 6: Supabase client + auth + middleware

**Files:**
- Create: `demo/src/lib/supabase/client.ts`
- Create: `demo/src/lib/supabase/server.ts`
- Create: `demo/src/lib/supabase/middleware.ts`
- Create: `demo/src/middleware.ts`

**Step 1: Browser client**

```typescript
// demo/src/lib/supabase/client.ts
import { createBrowserClient } from '@supabase/ssr'

export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  )
}
```

**Step 2: Server client**

```typescript
// demo/src/lib/supabase/server.ts
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'

export async function createClient() {
  const cookieStore = await cookies()

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options)
            )
          } catch {
            // Server Component — can't set cookies, ignore
          }
        },
      },
    }
  )
}
```

**Step 3: Middleware helper**

```typescript
// demo/src/lib/supabase/middleware.ts
import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value)
          )
          supabaseResponse = NextResponse.next({ request })
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options)
          )
        },
      },
    }
  )

  // Refresh session
  await supabase.auth.getUser()

  return supabaseResponse
}
```

**Step 4: Middleware entry point**

```typescript
// demo/src/middleware.ts
import { updateSession } from '@/lib/supabase/middleware'
import type { NextRequest } from 'next/server'

export async function middleware(request: NextRequest) {
  return await updateSession(request)
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)'],
}
```

**Step 5: Verify app starts**

```bash
cd demo && npm run dev
```

Expected: app starts on http://localhost:3000 without errors. Kill the dev server.

**Step 6: Commit**

```bash
git add demo/src/lib/supabase/ demo/src/middleware.ts
git commit -m "feat(demo): add Supabase client, server client, and auth middleware"
```

---

## Task 7: Types + layout + cart context

**Files:**
- Create: `demo/src/types/database.ts`
- Create: `demo/src/lib/cart-context.tsx`
- Modify: `demo/src/app/layout.tsx`
- Create: `demo/src/components/Navbar.tsx`

**Step 1: Database types**

```typescript
// demo/src/types/database.ts
export interface Event {
  id: string
  name: string
  description: string | null
  date: string
  venue: string
  location: string
  image_url: string | null
  ticket_price: number
  total_tickets: number
  created_at: string
}

export interface CartItem {
  id: string
  user_id: string
  event_id: string
  ticket_count: number
  expires_at: string
  created_at: string
  // Joined from events table
  event?: Event
}

export interface Order {
  id: string
  user_id: string
  total_amount: number
  created_at: string
}

export interface OrderItem {
  id: string
  order_id: string
  event_id: string
  ticket_count: number
  unit_price: number
  event?: Event
}
```

**Step 2: Cart context**

```tsx
// demo/src/lib/cart-context.tsx
'use client'

import { createContext, useContext, useState, useEffect, useCallback, type ReactNode } from 'react'
import { createClient } from '@/lib/supabase/client'
import type { CartItem } from '@/types/database'

interface CartContextType {
  items: CartItem[]
  loading: boolean
  soonestExpiry: Date | null
  refresh: () => Promise<void>
  addToCart: (eventId: string, count: number) => Promise<{ success: boolean; error?: string }>
  removeFromCart: (eventId: string) => Promise<void>
  checkout: () => Promise<{ orderId: string | null; error?: string }>
}

const CartContext = createContext<CartContextType | null>(null)

export function CartProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<CartItem[]>([])
  const [loading, setLoading] = useState(true)
  const supabase = createClient()

  const refresh = useCallback(async () => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      setItems([])
      setLoading(false)
      return
    }

    const { data } = await supabase
      .from('cart_items')
      .select('*, event:events(*)')
      .order('created_at')

    setItems(data ?? [])
    setLoading(false)
  }, [supabase])

  useEffect(() => {
    refresh()

    // Listen for auth changes
    const { data: { subscription } } = supabase.auth.onAuthStateChange(() => {
      refresh()
    })

    return () => subscription.unsubscribe()
  }, [supabase, refresh])

  // Remove expired items client-side
  useEffect(() => {
    const interval = setInterval(() => {
      const now = new Date()
      const expired = items.filter(item => new Date(item.expires_at) <= now)
      if (expired.length > 0) {
        // Unclaim expired items
        expired.forEach(async (item) => {
          await supabase.rpc('unclaim_tickets', { p_event_id: item.event_id })
        })
        refresh()
      }
    }, 1000)

    return () => clearInterval(interval)
  }, [items, supabase, refresh])

  const soonestExpiry = items.length > 0
    ? new Date(Math.min(...items.map(i => new Date(i.expires_at).getTime())))
    : null

  const addToCart = async (eventId: string, count: number) => {
    const { data, error } = await supabase.rpc('claim_tickets', {
      p_event_id: eventId,
      p_count: count,
    })

    if (error) return { success: false, error: error.message }
    if (!data) return { success: false, error: 'Not enough tickets available' }

    await refresh()
    return { success: true }
  }

  const removeFromCart = async (eventId: string) => {
    await supabase.rpc('unclaim_tickets', { p_event_id: eventId })
    await refresh()
  }

  const checkout = async () => {
    const { data, error } = await supabase.rpc('checkout_cart')

    if (error) return { orderId: null, error: error.message }

    await refresh()
    return { orderId: data }
  }

  return (
    <CartContext.Provider value={{ items, loading, soonestExpiry, refresh, addToCart, removeFromCart, checkout }}>
      {children}
    </CartContext.Provider>
  )
}

export function useCart() {
  const ctx = useContext(CartContext)
  if (!ctx) throw new Error('useCart must be used within CartProvider')
  return ctx
}
```

**Step 3: Navbar component**

```tsx
// demo/src/components/Navbar.tsx
'use client'

import Link from 'next/link'
import { useEffect, useState } from 'react'
import { createClient } from '@/lib/supabase/client'
import { useCart } from '@/lib/cart-context'
import type { User } from '@supabase/supabase-js'

function CountdownBadge({ expiresAt }: { expiresAt: Date }) {
  const [remaining, setRemaining] = useState('')

  useEffect(() => {
    const tick = () => {
      const diff = expiresAt.getTime() - Date.now()
      if (diff <= 0) { setRemaining('0:00'); return }
      const mins = Math.floor(diff / 60000)
      const secs = Math.floor((diff % 60000) / 1000)
      setRemaining(`${mins}:${secs.toString().padStart(2, '0')}`)
    }
    tick()
    const id = setInterval(tick, 1000)
    return () => clearInterval(id)
  }, [expiresAt])

  const diff = expiresAt.getTime() - Date.now()
  const urgent = diff < 120000 // < 2 minutes

  return (
    <span className={`text-xs font-mono ${urgent ? 'text-red-400' : 'text-zinc-400'}`}>
      {remaining}
    </span>
  )
}

export default function Navbar() {
  const [user, setUser] = useState<User | null>(null)
  const supabase = createClient()
  const { items, soonestExpiry } = useCart()

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => setUser(data.user))
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_, session) => {
      setUser(session?.user ?? null)
    })
    return () => subscription.unsubscribe()
  }, [supabase])

  const handleSignOut = async () => {
    await supabase.auth.signOut()
    window.location.href = '/'
  }

  return (
    <nav className="sticky top-0 z-50 border-b border-zinc-800 bg-zinc-950/90 backdrop-blur">
      <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3">
        <div className="flex items-center gap-6">
          <Link href="/" className="text-lg font-bold text-white">Tickets</Link>
          <Link href="/" className="text-sm text-zinc-400 hover:text-white">Home</Link>
          <Link href="/about" className="text-sm text-zinc-400 hover:text-white">About</Link>
        </div>

        <div className="flex items-center gap-4">
          {user ? (
            <>
              <Link href="/cart" className="relative flex items-center gap-1 text-sm text-zinc-400 hover:text-white">
                Cart
                {items.length > 0 && (
                  <span className="flex items-center gap-1">
                    <span className="rounded-full bg-cyan-500 px-1.5 py-0.5 text-xs font-bold text-black">
                      {items.length}
                    </span>
                    {soonestExpiry && <CountdownBadge expiresAt={soonestExpiry} />}
                  </span>
                )}
              </Link>
              <Link href="/account" className="text-sm text-zinc-400 hover:text-white">Account</Link>
              <button onClick={handleSignOut} className="text-sm text-zinc-400 hover:text-white">
                Sign Out
              </button>
            </>
          ) : (
            <Link href="/auth/login" className="text-sm text-zinc-400 hover:text-white">Sign In</Link>
          )}
        </div>
      </div>
    </nav>
  )
}
```

**Step 4: Root layout**

Replace `demo/src/app/layout.tsx`:

```tsx
// demo/src/app/layout.tsx
import type { Metadata } from 'next'
import { Inter } from 'next/font/google'
import './globals.css'
import Navbar from '@/components/Navbar'
import { CartProvider } from '@/lib/cart-context'

const inter = Inter({ subsets: ['latin'] })

export const metadata: Metadata = {
  title: 'Ticket Marketplace',
  description: 'Burst-to-Queue Ledger demo — a ticket marketplace powered by Supabase',
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <body className={`${inter.className} bg-zinc-950 text-zinc-100 antialiased`}>
        <CartProvider>
          <Navbar />
          <main className="mx-auto max-w-6xl px-4 py-8">
            {children}
          </main>
        </CartProvider>
      </body>
    </html>
  )
}
```

**Step 5: Update globals.css** (replace default Tailwind content in `demo/src/app/globals.css`):

```css
@tailwind base;
@tailwind components;
@tailwind utilities;
```

**Step 6: Verify app builds**

```bash
cd demo && npm run build
```

Expected: builds without errors (pages will be mostly empty but structurally valid).

**Step 7: Commit**

```bash
git add demo/src/types/ demo/src/lib/cart-context.tsx demo/src/components/Navbar.tsx demo/src/app/layout.tsx demo/src/app/globals.css
git commit -m "feat(demo): add types, cart context, navbar with countdown timer"
```

---

## Task 8: Home page — event grid

**Files:**
- Create: `demo/src/components/EventCard.tsx`
- Modify: `demo/src/app/page.tsx`

**Step 1: EventCard component**

```tsx
// demo/src/components/EventCard.tsx
import Link from 'next/link'
import type { Event } from '@/types/database'

function AvailabilityBadge({ available, total }: { available: number; total: number }) {
  const pct = available / total
  const color = pct > 0.5 ? 'bg-emerald-500' : pct > 0.1 ? 'bg-amber-500' : pct > 0 ? 'bg-red-500' : 'bg-zinc-600'
  const label = available === 0 ? 'Sold Out' : `${available.toLocaleString()} left`

  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-semibold text-black ${color}`}>
      {label}
    </span>
  )
}

export default function EventCard({ event, available }: { event: Event; available: number }) {
  const date = new Date(event.date)

  return (
    <Link href={`/event/${event.id}`} className="group block overflow-hidden rounded-xl border border-zinc-800 bg-zinc-900 transition hover:border-zinc-600">
      <div className="relative h-48 overflow-hidden bg-gradient-to-br from-zinc-800 to-zinc-900">
        {event.image_url && (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={event.image_url} alt={event.name} className="h-full w-full object-cover transition group-hover:scale-105" />
        )}
        <div className="absolute right-2 top-2">
          <AvailabilityBadge available={available} total={event.total_tickets} />
        </div>
      </div>
      <div className="p-4">
        <h3 className="font-semibold text-white">{event.name}</h3>
        <p className="mt-1 text-sm text-zinc-400">
          {date.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' })}
        </p>
        <p className="text-sm text-zinc-500">{event.venue} — {event.location}</p>
        <p className="mt-2 text-lg font-bold text-cyan-400">${event.ticket_price.toFixed(2)}</p>
      </div>
    </Link>
  )
}
```

**Step 2: Home page**

```tsx
// demo/src/app/page.tsx
import { createClient } from '@/lib/supabase/server'
import EventCard from '@/components/EventCard'
import type { Event } from '@/types/database'

export const revalidate = 30 // ISR: refresh every 30 seconds

export default async function HomePage() {
  const supabase = await createClient()

  const { data: events } = await supabase
    .from('events')
    .select('*')
    .order('date')

  // Fetch availability for each event
  const availability: Record<string, number> = {}
  if (events) {
    await Promise.all(
      events.map(async (event: Event) => {
        const { data } = await supabase.rpc('get_event_availability', { p_event_id: event.id })
        availability[event.id] = data ?? 0
      })
    )
  }

  return (
    <div>
      <h1 className="mb-2 text-3xl font-bold">Upcoming Events</h1>
      <p className="mb-8 text-zinc-400">Find and book tickets for live events</p>

      <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
        {events?.map((event: Event) => (
          <EventCard key={event.id} event={event} available={availability[event.id] ?? 0} />
        ))}
      </div>

      {(!events || events.length === 0) && (
        <p className="text-center text-zinc-500">No events available.</p>
      )}
    </div>
  )
}
```

**Step 3: Verify locally**

```bash
cd db2 && supabase start  # ensure DB2 is running
cd demo && npm run dev     # start Next.js
```

Visit http://localhost:3000 — should see 6 event cards with images, availability, prices.

**Step 4: Commit**

```bash
git add demo/src/components/EventCard.tsx demo/src/app/page.tsx
git commit -m "feat(demo): add event grid home page with availability badges"
```

---

## Task 9: Event detail + add to cart

**Files:**
- Create: `demo/src/app/event/[id]/page.tsx`
- Create: `demo/src/components/TicketSelector.tsx`
- Create: `demo/src/components/AddToCartModal.tsx`

**Step 1: TicketSelector component**

```tsx
// demo/src/components/TicketSelector.tsx
'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useCart } from '@/lib/cart-context'
import { createClient } from '@/lib/supabase/client'
import AddToCartModal from './AddToCartModal'

export default function TicketSelector({ eventId, available, price }: {
  eventId: string
  available: number
  price: number
}) {
  const [count, setCount] = useState(1)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [showModal, setShowModal] = useState(false)
  const { addToCart } = useCart()
  const router = useRouter()
  const supabase = createClient()

  const maxTickets = Math.min(available, 10) // cap at 10 per transaction

  const handleAddToCart = async () => {
    setLoading(true)
    setError(null)

    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      router.push('/auth/login')
      return
    }

    const result = await addToCart(eventId, count)
    setLoading(false)

    if (result.success) {
      setShowModal(true)
    } else {
      setError(result.error ?? 'Failed to add tickets')
    }
  }

  if (available === 0) {
    return <div className="rounded-lg bg-zinc-800 p-6 text-center text-zinc-400">Sold Out</div>
  }

  return (
    <>
      <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-6">
        <div className="mb-4 flex items-center justify-between">
          <label className="text-sm text-zinc-400">Number of tickets</label>
          <select
            value={count}
            onChange={(e) => setCount(Number(e.target.value))}
            className="rounded bg-zinc-800 px-3 py-1 text-white"
          >
            {Array.from({ length: maxTickets }, (_, i) => i + 1).map((n) => (
              <option key={n} value={n}>{n}</option>
            ))}
          </select>
        </div>

        <div className="mb-4 flex items-center justify-between border-t border-zinc-800 pt-4">
          <span className="text-zinc-400">Total</span>
          <span className="text-2xl font-bold text-white">${(price * count).toFixed(2)}</span>
        </div>

        {error && <p className="mb-4 text-sm text-red-400">{error}</p>}

        <button
          onClick={handleAddToCart}
          disabled={loading}
          className="w-full rounded-lg bg-cyan-500 py-3 font-semibold text-black transition hover:bg-cyan-400 disabled:opacity-50"
        >
          {loading ? 'Reserving...' : 'Add to Cart'}
        </button>

        <p className="mt-2 text-center text-xs text-zinc-500">
          Tickets are held for 20 minutes
        </p>
      </div>

      {showModal && <AddToCartModal onClose={() => setShowModal(false)} />}
    </>
  )
}
```

**Step 2: AddToCartModal component**

```tsx
// demo/src/components/AddToCartModal.tsx
'use client'

import { useRouter } from 'next/navigation'

export default function AddToCartModal({ onClose }: { onClose: () => void }) {
  const router = useRouter()

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="w-full max-w-sm rounded-xl border border-zinc-700 bg-zinc-900 p-6">
        <h2 className="mb-2 text-xl font-bold text-white">Added to Cart!</h2>
        <p className="mb-6 text-sm text-zinc-400">
          Your tickets are reserved for 20 minutes.
        </p>

        <div className="flex gap-3">
          <button
            onClick={() => router.push('/cart')}
            className="flex-1 rounded-lg bg-cyan-500 py-2 font-semibold text-black hover:bg-cyan-400"
          >
            Checkout
          </button>
          <button
            onClick={() => { onClose(); router.push('/') }}
            className="flex-1 rounded-lg border border-zinc-600 py-2 font-semibold text-zinc-300 hover:bg-zinc-800"
          >
            Continue Shopping
          </button>
        </div>
      </div>
    </div>
  )
}
```

**Step 3: Event detail page**

```tsx
// demo/src/app/event/[id]/page.tsx
import { createClient } from '@/lib/supabase/server'
import { notFound } from 'next/navigation'
import TicketSelector from '@/components/TicketSelector'

export const revalidate = 10

export default async function EventPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
  const supabase = await createClient()

  const { data: event } = await supabase
    .from('events')
    .select('*')
    .eq('id', id)
    .single()

  if (!event) notFound()

  const { data: available } = await supabase.rpc('get_event_availability', { p_event_id: id })
  const date = new Date(event.date)

  return (
    <div className="grid gap-8 lg:grid-cols-3">
      <div className="lg:col-span-2">
        <div className="mb-6 h-64 overflow-hidden rounded-xl bg-gradient-to-br from-zinc-800 to-zinc-900 lg:h-80">
          {event.image_url && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={event.image_url} alt={event.name} className="h-full w-full object-cover" />
          )}
        </div>

        <h1 className="mb-2 text-3xl font-bold">{event.name}</h1>

        <div className="mb-4 flex flex-wrap gap-4 text-sm text-zinc-400">
          <span>{date.toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}</span>
          <span>{date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })}</span>
        </div>

        <div className="mb-6 flex gap-4 text-sm">
          <span className="text-zinc-400">{event.venue}</span>
          <span className="text-zinc-500">{event.location}</span>
        </div>

        {event.description && (
          <p className="text-zinc-300 leading-relaxed">{event.description}</p>
        )}
      </div>

      <div>
        <TicketSelector eventId={id} available={available ?? 0} price={event.ticket_price} />
      </div>
    </div>
  )
}
```

**Step 4: Verify locally**

Visit http://localhost:3000, click an event card. Should see detail page with image, info, and ticket selector.

**Step 5: Commit**

```bash
git add demo/src/app/event/ demo/src/components/TicketSelector.tsx demo/src/components/AddToCartModal.tsx
git commit -m "feat(demo): add event detail page with ticket selector and add-to-cart modal"
```

---

## Task 10: Cart page + checkout

**Files:**
- Create: `demo/src/app/cart/page.tsx`
- Create: `demo/src/components/CartItemRow.tsx`
- Create: `demo/src/app/checkout/confirmation/page.tsx`

**Step 1: CartItemRow component**

```tsx
// demo/src/components/CartItemRow.tsx
'use client'

import { useEffect, useState } from 'react'
import { useCart } from '@/lib/cart-context'

export default function CartItemRow({ item }: { item: { event_id: string; ticket_count: number; expires_at: string; event?: { name: string; ticket_price: number; venue: string } } }) {
  const { removeFromCart } = useCart()
  const [remaining, setRemaining] = useState('')
  const [removing, setRemoving] = useState(false)

  useEffect(() => {
    const tick = () => {
      const diff = new Date(item.expires_at).getTime() - Date.now()
      if (diff <= 0) { setRemaining('Expired'); return }
      const mins = Math.floor(diff / 60000)
      const secs = Math.floor((diff % 60000) / 1000)
      setRemaining(`${mins}:${secs.toString().padStart(2, '0')}`)
    }
    tick()
    const id = setInterval(tick, 1000)
    return () => clearInterval(id)
  }, [item.expires_at])

  const expired = new Date(item.expires_at).getTime() <= Date.now()
  const diff = new Date(item.expires_at).getTime() - Date.now()
  const urgent = diff < 120000

  const handleRemove = async () => {
    setRemoving(true)
    await removeFromCart(item.event_id)
  }

  if (expired) return null

  return (
    <div className="flex items-center justify-between rounded-lg border border-zinc-800 bg-zinc-900 p-4">
      <div className="flex-1">
        <h3 className="font-semibold text-white">{item.event?.name ?? 'Unknown Event'}</h3>
        <p className="text-sm text-zinc-400">
          {item.ticket_count} ticket{item.ticket_count > 1 ? 's' : ''} × ${item.event?.ticket_price.toFixed(2)}
        </p>
        <p className="text-xs text-zinc-500">{item.event?.venue}</p>
      </div>

      <div className="flex items-center gap-4">
        <div className="text-right">
          <p className="font-bold text-white">
            ${((item.event?.ticket_price ?? 0) * item.ticket_count).toFixed(2)}
          </p>
          <p className={`text-xs font-mono ${urgent ? 'text-red-400' : 'text-zinc-400'}`}>
            {remaining}
          </p>
        </div>

        <button
          onClick={handleRemove}
          disabled={removing}
          className="rounded px-3 py-1 text-sm text-zinc-400 hover:bg-zinc-800 hover:text-white"
        >
          {removing ? '...' : 'Remove'}
        </button>
      </div>
    </div>
  )
}
```

**Step 2: Cart page**

```tsx
// demo/src/app/cart/page.tsx
'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useCart } from '@/lib/cart-context'
import CartItemRow from '@/components/CartItemRow'

export default function CartPage() {
  const { items, loading, checkout } = useCart()
  const [checkingOut, setCheckingOut] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const router = useRouter()

  const activeItems = items.filter(i => new Date(i.expires_at).getTime() > Date.now())
  const total = activeItems.reduce((sum, item) => {
    return sum + (item.event?.ticket_price ?? 0) * item.ticket_count
  }, 0)

  const handleCheckout = async () => {
    setCheckingOut(true)
    setError(null)
    const result = await checkout()
    setCheckingOut(false)

    if (result.orderId) {
      router.push(`/checkout/confirmation?order=${result.orderId}`)
    } else {
      setError(result.error ?? 'Checkout failed')
    }
  }

  if (loading) {
    return <p className="text-zinc-400">Loading cart...</p>
  }

  return (
    <div className="mx-auto max-w-2xl">
      <h1 className="mb-6 text-3xl font-bold">Your Cart</h1>

      {activeItems.length === 0 ? (
        <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-8 text-center">
          <p className="text-zinc-400">Your cart is empty.</p>
          <a href="/" className="mt-4 inline-block text-cyan-400 hover:underline">Browse events</a>
        </div>
      ) : (
        <>
          <div className="mb-6 space-y-3">
            {activeItems.map(item => (
              <CartItemRow key={item.id} item={item} />
            ))}
          </div>

          <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-6">
            <div className="mb-4 flex items-center justify-between">
              <span className="text-lg text-zinc-400">Total</span>
              <span className="text-2xl font-bold text-white">${total.toFixed(2)}</span>
            </div>

            {error && <p className="mb-4 text-sm text-red-400">{error}</p>}

            <button
              onClick={handleCheckout}
              disabled={checkingOut}
              className="w-full rounded-lg bg-cyan-500 py-3 font-semibold text-black transition hover:bg-cyan-400 disabled:opacity-50"
            >
              {checkingOut ? 'Processing...' : 'Complete Purchase'}
            </button>

            <p className="mt-2 text-center text-xs text-zinc-500">
              Demo mode — no payment required
            </p>
          </div>
        </>
      )}
    </div>
  )
}
```

**Step 3: Confirmation page**

```tsx
// demo/src/app/checkout/confirmation/page.tsx
import Link from 'next/link'

export default async function ConfirmationPage({ searchParams }: { searchParams: Promise<{ order?: string }> }) {
  const { order } = await searchParams

  return (
    <div className="mx-auto max-w-md text-center">
      <div className="mb-6 text-6xl">✓</div>
      <h1 className="mb-2 text-3xl font-bold">Purchase Confirmed!</h1>
      <p className="mb-2 text-zinc-400">Your tickets have been booked.</p>
      {order && <p className="mb-6 text-xs text-zinc-500">Order: {order}</p>}

      <div className="flex justify-center gap-4">
        <Link href="/account" className="rounded-lg bg-cyan-500 px-6 py-2 font-semibold text-black hover:bg-cyan-400">
          View Orders
        </Link>
        <Link href="/" className="rounded-lg border border-zinc-600 px-6 py-2 font-semibold text-zinc-300 hover:bg-zinc-800">
          Browse Events
        </Link>
      </div>
    </div>
  )
}
```

**Step 4: Verify locally**

Sign up, add tickets to cart, verify timer counts down, checkout, verify confirmation page.

**Step 5: Commit**

```bash
git add demo/src/app/cart/ demo/src/components/CartItemRow.tsx demo/src/app/checkout/
git commit -m "feat(demo): add cart page with countdown timers and checkout flow"
```

---

## Task 11: Account + auth + about pages

**Files:**
- Create: `demo/src/app/account/page.tsx`
- Create: `demo/src/app/auth/login/page.tsx`
- Create: `demo/src/app/about/page.tsx`

**Step 1: Login page**

```tsx
// demo/src/app/auth/login/page.tsx
'use client'

import { Auth } from '@supabase/auth-ui-react'
import { ThemeSupa } from '@supabase/auth-ui-shared'
import { createClient } from '@/lib/supabase/client'
import { useRouter } from 'next/navigation'
import { useEffect } from 'react'

export default function LoginPage() {
  const supabase = createClient()
  const router = useRouter()

  useEffect(() => {
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_IN') {
        router.push('/')
      }
    })
    return () => subscription.unsubscribe()
  }, [supabase, router])

  return (
    <div className="mx-auto max-w-sm">
      <h1 className="mb-6 text-center text-2xl font-bold">Sign In</h1>
      <Auth
        supabaseClient={supabase}
        appearance={{
          theme: ThemeSupa,
          variables: {
            default: {
              colors: {
                brand: '#06b6d4',
                brandAccent: '#22d3ee',
              },
            },
          },
        }}
        theme="dark"
        providers={[]}
      />
    </div>
  )
}
```

**Step 2: Account page**

```tsx
// demo/src/app/account/page.tsx
import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import type { Order, OrderItem } from '@/types/database'

export default async function AccountPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) redirect('/auth/login')

  const { data: orders } = await supabase
    .from('orders')
    .select('*, order_items:order_items(*, event:events(name, venue, date))')
    .order('created_at', { ascending: false })

  return (
    <div className="mx-auto max-w-2xl">
      <h1 className="mb-2 text-3xl font-bold">Account</h1>
      <p className="mb-8 text-zinc-400">{user.email}</p>

      <h2 className="mb-4 text-xl font-semibold">Purchase History</h2>

      {(!orders || orders.length === 0) ? (
        <p className="text-zinc-500">No purchases yet.</p>
      ) : (
        <div className="space-y-4">
          {orders.map((order: Order & { order_items: (OrderItem & { event: { name: string; venue: string; date: string } })[] }) => (
            <div key={order.id} className="rounded-lg border border-zinc-800 bg-zinc-900 p-4">
              <div className="mb-2 flex items-center justify-between">
                <span className="text-sm text-zinc-400">
                  {new Date(order.created_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })}
                </span>
                <span className="font-bold text-white">${order.total_amount.toFixed(2)}</span>
              </div>

              {order.order_items.map((item) => (
                <div key={item.id} className="flex justify-between text-sm">
                  <span className="text-zinc-300">
                    {item.event?.name} — {item.ticket_count} ticket{item.ticket_count > 1 ? 's' : ''}
                  </span>
                  <span className="text-zinc-400">${(item.unit_price * item.ticket_count).toFixed(2)}</span>
                </div>
              ))}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
```

**Step 3: About page**

```tsx
// demo/src/app/about/page.tsx
export default function AboutPage() {
  return (
    <div className="mx-auto max-w-2xl">
      <h1 className="mb-4 text-3xl font-bold">About</h1>

      <div className="space-y-4 text-zinc-300 leading-relaxed">
        <p>
          This is a demo ticket marketplace built on{' '}
          <a href="https://supabase.com" className="text-cyan-400 hover:underline" target="_blank" rel="noopener noreferrer">
            Supabase
          </a>
          , demonstrating the{' '}
          <strong className="text-white">Burst-to-Queue Ledger</strong>{' '}
          architecture for high-concurrency ticket sales.
        </p>

        <p>
          The system handles up to <strong className="text-white">1,000 claims per second</strong>{' '}
          with zero errors — enough to sell out a 50,000-seat stadium in under a minute.
        </p>

        <p>
          Read the full technical explainer:{' '}
          <a href="https://dventimisupabase.github.io/pg-ticketing-system/" className="text-cyan-400 hover:underline" target="_blank" rel="noopener noreferrer">
            Burst-to-Queue Ledger
          </a>
        </p>
      </div>
    </div>
  )
}
```

**Step 4: Verify all pages locally**

- Visit `/auth/login` — sign up form appears
- Sign up with email/password
- Visit `/account` — shows email, empty order history
- Visit `/about` — static content renders

**Step 5: Commit**

```bash
git add demo/src/app/account/ demo/src/app/auth/ demo/src/app/about/
git commit -m "feat(demo): add auth, account, and about pages"
```

---

## Task 12: Vercel deployment

**Step 1: Configure Next.js for production**

Verify `demo/next.config.ts` has no issues. The default from `create-next-app` should work.

**Step 2: Add Vercel-specific settings (optional)**

No `vercel.json` needed — Vercel auto-detects Next.js projects. Just ensure the root directory is set to `demo/` in Vercel project settings.

**Step 3: Deploy**

Option A — Via Vercel CLI:

```bash
cd demo && npx vercel --prod
```

Option B — Connect GitHub repo in Vercel dashboard:
1. Go to https://vercel.com/new
2. Import the `pg-ticketing-system` repo
3. Set "Root Directory" to `demo`
4. Add environment variables:
   - `NEXT_PUBLIC_SUPABASE_URL` = your cloud DB2 URL
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY` = your cloud DB2 anon key

**Step 4: Apply DB2 migration to cloud**

```bash
cd db2 && supabase db push
```

Or copy migration SQL to the Supabase dashboard SQL editor.

**Step 5: Seed cloud DB2**

Copy `seed.sql` contents and run in the Supabase SQL editor (seeds don't run on `db push`).

**Step 6: Verify production deployment**

Visit the Vercel URL, browse events, sign up, add tickets, checkout, verify account page.

**Step 7: Commit any deployment config changes**

```bash
git add -A && git commit -m "feat(demo): configure Vercel deployment"
```

---

## Summary

| Task | Files | Key outcome |
|------|-------|-------------|
| 1 | `db2/supabase/migrations/20260304200000_marketplace_schema.sql` | Tables, types, indexes, RLS |
| 2 | `db2/supabase/migrations/20260304200001_marketplace_functions.sql` | 5 RPC functions |
| 3 | `db2/supabase/tests/00002_marketplace.test.sql` | 20 pgTAP tests |
| 4 | `db2/supabase/seed.sql`, `...20260304200002_marketplace_cron.sql` | 6 events + 91.5k tickets + reaper |
| 5 | `demo/` (scaffold) | Next.js app with Supabase deps |
| 6 | `demo/src/lib/supabase/`, `demo/src/middleware.ts` | Auth + SSR client |
| 7 | `demo/src/types/`, `demo/src/lib/cart-context.tsx`, Navbar, layout | Cart state + countdown timer |
| 8 | `demo/src/app/page.tsx`, `EventCard.tsx` | Event grid home page |
| 9 | `demo/src/app/event/[id]/`, `TicketSelector.tsx`, `AddToCartModal.tsx` | Event detail + add to cart |
| 10 | `demo/src/app/cart/`, `CartItemRow.tsx`, confirmation page | Cart with timers + checkout |
| 11 | `demo/src/app/account/`, `demo/src/app/auth/login/`, `demo/src/app/about/` | Auth, account, about |
| 12 | Vercel config | Production deployment |
