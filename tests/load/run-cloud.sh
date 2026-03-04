#!/usr/bin/env bash
# tests/load/run-cloud.sh
# Cloud-scale benchmark: shielded vs unshielded via Grafana Cloud k6.
# Usage: ./tests/load/run-cloud.sh [spike|ramp|sustained]  (default: spike)

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
: "${DB2_URL:?DB2_URL must be set in .env.cloud}"
: "${DB1_KEY:?DB1_KEY must be set in .env.cloud}"
: "${DB2_KEY:?DB2_KEY must be set in .env.cloud}"
: "${K6_CLOUD_TOKEN:?K6_CLOUD_TOKEN must be set in .env.cloud}"

SCENARIO="${1:-spike}"
echo "=== Cloud load test: $SCENARIO scenario ($(date)) ==="

# --- REST helpers ---
db1_post() { curl -sf -X POST "$DB1_URL/rest/v1/$1" \
  -H "apikey: $DB1_KEY" -H "Authorization: Bearer $DB1_KEY" \
  -H "Content-Type: application/json" -H "Prefer: $2" -d "$3"; }

db1_delete() { curl -sf -X DELETE "$DB1_URL/rest/v1/$1" \
  -H "apikey: $DB1_KEY" -H "Authorization: Bearer $DB1_KEY"; }

db2_delete() { curl -sf -X DELETE "$DB2_URL/rest/v1/$1" \
  -H "apikey: $DB2_KEY" -H "Authorization: Bearer $DB2_KEY"; }

setup_db1() {
  echo "--- Setting up load_test pool on cloud DB1 ---"

  db1_post "engine_config" "resolution=ignore-duplicates" \
    '{"pool_id":"load_test","batch_size":100,"visibility_timeout_sec":45,"max_retries":10,"is_active":true}'

  db1_delete "inventory_slots?pool_id=eq.load_test"

  echo "    Inserting 500k inventory slots (50 batches of 10k)..."
  BATCH=$(python3 -c "import json; print(json.dumps([{'pool_id':'load_test','status':'AVAILABLE'}]*10000))")
  for i in $(seq 1 50); do
    db1_post "inventory_slots" "return=minimal" "$BATCH" > /dev/null
    printf "    %d/50\r" "$i"
  done
  echo ""
}

cleanup() {
  echo "--- Cleaning up between runs ---"
  db1_delete "inventory_slots?pool_id=eq.load_test"
  db2_delete "confirmed_tickets?pool_id=eq.load_test"
}

teardown() {
  echo "--- Tearing down ---"
  db1_delete "inventory_slots?pool_id=eq.load_test"
  db1_delete "engine_metrics?pool_id=eq.load_test"
  db2_delete "confirmed_tickets?pool_id=eq.load_test"
}

setup_db1

echo "--- Running SHIELDED scenario (cloud scale) ---"
k6 cloud run \
  -e SCENARIO="$SCENARIO" \
  -e CLOUD_SCALE=1 \
  -e DB1_URL="$DB1_URL" \
  -e DB1_KEY="$DB1_KEY" \
  "$SCRIPT_DIR/shielded.js"

cleanup
setup_db1

echo "--- Running UNSHIELDED scenario (cloud scale) ---"
k6 cloud run \
  -e SCENARIO="$SCENARIO" \
  -e CLOUD_SCALE=1 \
  -e DB2_URL="$DB2_URL" \
  -e DB2_KEY="$DB2_KEY" \
  "$SCRIPT_DIR/unshielded.js"

teardown

echo ""
echo "=== Results in Grafana Cloud k6 dashboard: https://app.k6.io ==="
