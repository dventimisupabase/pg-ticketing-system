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
: "${DB1_POSTGRES_URL:?DB1_POSTGRES_URL must be set in .env.cloud}"
: "${DB2_POSTGRES_URL:?DB2_POSTGRES_URL must be set in .env.cloud}"
: "${K6_CLOUD_TOKEN:?K6_CLOUD_TOKEN must be set in .env.cloud}"

SCENARIO="${1:-spike}"
echo "=== Cloud load test: $SCENARIO scenario ($(date)) ==="

echo "--- Setting up load_test pool on cloud DB1 ---"
psql "$DB1_POSTGRES_URL" -f "$SCRIPT_DIR/setup.sql"

echo "--- Running SHIELDED scenario (cloud scale) ---"
k6 cloud run \
  -e SCENARIO="$SCENARIO" \
  -e CLOUD_SCALE=1 \
  -e DB1_URL="$DB1_URL" \
  -e DB1_KEY="$DB1_KEY" \
  "$SCRIPT_DIR/shielded.js"

echo "--- Cleaning up between runs ---"
psql "$DB1_POSTGRES_URL" -c "DELETE FROM inventory_slots WHERE pool_id = 'load_test';"
psql "$DB2_POSTGRES_URL" -c "DELETE FROM confirmed_tickets WHERE pool_id = 'load_test';"
psql "$DB1_POSTGRES_URL" -f "$SCRIPT_DIR/setup.sql"

echo "--- Running UNSHIELDED scenario (cloud scale) ---"
k6 cloud run \
  -e SCENARIO="$SCENARIO" \
  -e CLOUD_SCALE=1 \
  -e DB2_URL="$DB2_URL" \
  -e DB2_KEY="$DB2_KEY" \
  "$SCRIPT_DIR/unshielded.js"

echo "--- Tearing down ---"
psql "$DB1_POSTGRES_URL" -f "$SCRIPT_DIR/teardown.sql"
psql "$DB2_POSTGRES_URL" -c "DELETE FROM confirmed_tickets WHERE pool_id = 'load_test';"

echo ""
echo "=== Results in Grafana Cloud k6 dashboard: https://app.k6.io ==="
