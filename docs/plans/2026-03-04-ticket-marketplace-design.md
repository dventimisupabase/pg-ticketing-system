# Ticket Marketplace Demo — Design

**Date:** 2026-03-04
**Status:** Approved

## Overview

Build a public-facing ticket marketplace demo that showcases the burst-to-queue ledger architecture. The marketplace is a real (albeit basic) ticket-selling application — like a simplified TicketMaster — built in phases:

- **Phase 1:** DB2 standalone marketplace (the "legacy" app)
- **Phase 2:** DB1 shield + bridge edge function (deferred, plans adjusted after Phase 1)
- **Phase 3:** Rewire the hot path in the web app to use DB1 (deferred, plans adjusted after Phase 2)

The narrative: DB2 and its web application exist first. Later, we perceive the need for a shield and bolt DB1 onto it — only for the hot path (check inventory, claim, unclaim). Everything else stays on DB2.

## Architecture

### Phase 1 — DB2 Standalone Marketplace

```
Browser ←→ Next.js (Vercel) ←→ DB2 (Supabase)
```

- Next.js app on Vercel
- Supabase Auth on DB2
- Simple row-level reservations with pg_cron reaper
- Full claim/cart/timer/checkout flow

### Phase 2-3 — DB1 Shield (deferred, high-level sketch)

```
Browser → DB2 (events, auth, account, cart, checkout)
Browser → DB1 (check inventory, claim batch, unclaim)
DB1 → Bridge Edge Function → DB2 (confirm purchase)
```

DB1 handles only three operations. Everything else stays on DB2. Plans for Phases 2-3 will be refined based on Phase 1 learnings.

## Phase 1: DB2 Schema

### New Tables

| Table | Purpose | Key columns |
|-------|---------|-------------|
| `events` | Event catalog | `id`, `name`, `description`, `date`, `venue`, `location`, `image_url`, `ticket_price`, `total_tickets` |
| `event_tickets` | Individual ticket inventory | `id`, `event_id` (FK), `status` (AVAILABLE/RESERVED/SOLD), `reserved_by` (FK → auth.users), `reserved_at`, `seq_pos` |
| `cart_items` | Shopping cart entries | `id`, `user_id` (FK → auth.users), `event_id` (FK), `ticket_count`, `expires_at`, `created_at` |
| `orders` | Completed purchases | `id`, `user_id` (FK → auth.users), `total_amount`, `created_at` |
| `order_items` | Tickets in an order | `id`, `order_id` (FK), `event_id` (FK), `ticket_count`, `unit_price` |

Existing `confirmed_tickets` and `finalize_transaction` remain for future bridge integration.

### New Functions

| Function | Signature | Behavior |
|----------|-----------|----------|
| `claim_tickets` | `(p_event_id UUID, p_user_id UUID, p_count INT) → UUID[]` | All-or-nothing batch claim. Updates N tickets from AVAILABLE → RESERVED. Returns ticket IDs or NULL if insufficient inventory. |
| `unclaim_tickets` | `(p_event_id UUID, p_user_id UUID) → INT` | Releases user's RESERVED tickets for an event back to AVAILABLE. Returns count released. |
| `checkout_cart` | `(p_user_id UUID) → UUID` | Creates order from non-expired cart items. Moves tickets RESERVED → SOLD. Deletes cart items. Returns order ID. |
| `reap_expired_reservations` | `() → INT` | Cron job: finds RESERVED tickets where `reserved_at + 20min < NOW()`, sets back to AVAILABLE, deletes corresponding cart_items. |
| `get_event_availability` | `(p_event_id UUID) → INT` | Count of AVAILABLE tickets for an event. |

### Auth & RLS

- Supabase Auth on DB2
- `events`, `event_tickets`: readable by anon (public catalog)
- `cart_items`: scoped to `auth.uid()` (users see only their own cart)
- `orders`, `order_items`: scoped to `auth.uid()` (users see only their own orders)

### Seeded Data

5-8 fictional events with varied inventory sizes (500 to 50,000), mixing concerts, theater, and sports. Demonstrates the "venue sell-out table" from the explainer.

### Reaper

pg_cron job running `reap_expired_reservations()` every minute. Safety net for abandoned sessions.

## Phase 1: Next.js App

### Tech Stack

- Next.js on Vercel
- Supabase JS client (`@supabase/supabase-js`)
- Supabase Auth UI (`@supabase/auth-ui-react`)
- TypeScript

### Pages

| Route | Purpose | Data source |
|-------|---------|-------------|
| `/` | Event grid — tiles with image, name, date, venue, availability badge | DB2 `events` + `get_event_availability` |
| `/event/[id]` | Event detail — hero image, description, date/venue/location, ticket quantity selector, "Add to Cart" button | DB2 `events` |
| `/cart` | Shopping cart — items with countdown timers, remove button, "Checkout" button | DB2 `cart_items` + client-side timers |
| `/account` | User profile + purchase history | DB2 `orders` + `order_items` |
| `/auth/login` | Sign in / sign up (Supabase Auth UI) | Supabase Auth |
| `/about` | Static — project description, link to explainer | None |

### Layout

Global nav bar: Home, About, Account, Sign Out, cart icon with:
- Badge showing item count (an "item" = tickets for one event)
- Countdown timer showing time remaining for the item expiring soonest

### Key Interactions

1. **Add to Cart:** Select quantity → `claim_tickets(event_id, user_id, count)` → insert `cart_items` with `expires_at = NOW() + 20min` → modal: "Checkout" or "Continue Shopping"

2. **Cart timer:** Each item has independent `expires_at`. Nav shows countdown for soonest-expiring item. On expiry: `unclaim_tickets(event_id, user_id)`, remove cart item, toast notification.

3. **Remove from cart:** `unclaim_tickets` + delete `cart_items` row.

4. **Checkout:** `checkout_cart(user_id)` → creates order, tickets → SOLD, cart cleared → confirmation page.

5. **Auth gate:** `/cart`, `/account`, "Add to Cart" require auth → redirect to `/auth/login`.

### Visual Style

Clean, modern marketplace. Dark theme consistent with the explainer aesthetic but lighter — more like a real e-commerce site. Event tiles with hover effects. Availability badges (green/amber/red by remaining %).

## Phases 2-3: DB1 Shield (Deferred)

High-level sketch — to be refined after Phase 1:

### Phase 2: DB1 Additions

- `claim_batch(p_pool_id, p_user_id, p_count) → UUID[]` — all-or-nothing batch claim using sequential positions
- `unclaim_slots(p_pool_id, p_user_id) → INT` — explicit release back to AVAILABLE
- Bridge edge function: DB1 intake queue → DB2 `finalize_transaction` (or new `confirm_purchase`)
- Reaper `visibility_timeout_sec` set to 1200 (20 minutes) for marketplace pools
- Each DB2 event maps to a DB1 pool

### Phase 3: Rewire Hot Path

- Environment variable or route-based switching
- Only claim/unclaim calls go to DB1
- Cart, timers, checkout, auth, events all remain on DB2
- Adaptation code in DB2/web app as needed

## Phase 1 Deliverables

1. DB2 migration: tables, types, RLS policies
2. DB2 functions: claim_tickets, unclaim_tickets, checkout_cart, reap_expired_reservations, get_event_availability
3. DB2 seed script: 5-8 fictional events with inventory
4. DB2 pg_cron: reaper job
5. DB2 pgTAP tests
6. Next.js app: all pages and interactions
7. Vercel deployment
