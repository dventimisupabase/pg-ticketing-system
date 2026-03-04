-- db1/supabase/tests/00002_intake_functions.test.sql
BEGIN;
SELECT plan(13);

-- Setup: seed config and inventory
INSERT INTO engine_config (pool_id, batch_size, visibility_timeout_sec, max_retries, is_active)
VALUES ('test_pool', 10, 45, 3, true);

INSERT INTO inventory_slots (pool_id, status)
SELECT 'test_pool', 'AVAILABLE'
FROM generate_series(1, 5);

-- claim_resource_and_queue returns a UUID when slots available
SELECT isnt(
    claim_resource_and_queue('test_pool', 'user_1'),
    NULL,
    'claim_resource_and_queue returns UUID when slots available'
);

-- Claimed slot should be RESERVED
SELECT is(
    (SELECT status FROM inventory_slots WHERE locked_by = 'user_1' LIMIT 1),
    'RESERVED'::slot_status,
    'claimed slot status is RESERVED'
);

-- locked_by is set correctly
SELECT is(
    (SELECT locked_by FROM inventory_slots WHERE status = 'RESERVED' LIMIT 1),
    'user_1',
    'claimed slot locked_by is correct user'
);

-- Claim no longer enqueues (sweep handles that)
SELECT ok(
    (SELECT (SELECT queue_length FROM pgmq.metrics('intake_queue')) = 0),
    'claim does NOT enqueue a message in intake_queue'
);

-- Returns NULL when sold out (claim all remaining slots then try again)
SELECT claim_resource_and_queue('test_pool', 'user_2');
SELECT claim_resource_and_queue('test_pool', 'user_3');
SELECT claim_resource_and_queue('test_pool', 'user_4');
SELECT claim_resource_and_queue('test_pool', 'user_5');

SELECT is(
    claim_resource_and_queue('test_pool', 'user_overflow'),
    NULL,
    'claim returns NULL when sold out'
);

-- RPC wrappers exist
SELECT has_function('intake_queue_read', 'intake_queue_read function exists');
SELECT has_function('intake_queue_send', 'intake_queue_send function exists');
SELECT has_function('intake_queue_delete', 'intake_queue_delete function exists');
SELECT has_function('intake_route_to_dlq', 'intake_route_to_dlq function exists');
SELECT has_function('snapshot_engine_metrics', 'snapshot_engine_metrics function exists');

-- intake_queue_send returns a msg_id
SELECT ok(
    (SELECT intake_queue_send('{"test": true}'::jsonb) IS NOT NULL),
    'intake_queue_send returns a msg_id'
);

-- snapshot_engine_metrics inserts a row per active pool
SELECT snapshot_engine_metrics();
SELECT ok(
    (SELECT EXISTS (SELECT 1 FROM engine_metrics WHERE pool_id = 'test_pool')),
    'snapshot_engine_metrics inserts row for active pool'
);

-- intake_route_to_dlq moves message to DLQ
DO $$
DECLARE
    v_msg_id BIGINT;
    v_payload JSONB := '{"resource_id": "test-uuid", "pool_id": "test_pool", "user_id": "dlq_test", "state": "queued"}'::jsonb;
BEGIN
    v_msg_id := intake_queue_send(v_payload);
    PERFORM intake_route_to_dlq(v_msg_id, v_payload, 10);
END $$;

SELECT ok(
    (SELECT (SELECT queue_length FROM pgmq.metrics('intake_dlq')) > 0),
    'intake_route_to_dlq routes message to intake_dlq'
);

SELECT finish();
ROLLBACK;
