#!/usr/bin/env bash
# tests/load/download-results.sh
# Download test run summaries from Grafana Cloud k6.
#
# Usage:
#   ./tests/load/download-results.sh            # list recent runs
#   ./tests/load/download-results.sh <run_id>   # download a specific run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.cloud"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"
: "${K6_CLOUD_TOKEN:?K6_CLOUD_TOKEN must be set in .env.cloud}"

K6_API="https://api.k6.io"
PROJECT_ID=6883841

api_get() {
  curl -sf "$K6_API/$1" -H "Authorization: Token $K6_CLOUD_TOKEN"
}

download_run() {
  local run_id="$1"
  echo "--- Downloading run $run_id ---"

  # Run details
  local run_file="$RESULTS_DIR/cloud-run-${run_id}.json"
  api_get "loadtests/v2/runs/$run_id" | python3 -c "
import sys, json
d = json.load(sys.stdin)
run = d['k6-run']
summary = {
  'run_id':       run['id'],
  'test_name':    run.get('test_name', ''),
  'run_status':   run['run_status'],   # 3=finished
  'result_status': run['result_status'], # 0=passed, 1=failed (thresholds)
  'started':      run['started'],
  'ended':        run['ended'],
  'duration_sec': run['duration'],
  'vus':          run['vus'],
  'load_zone':    run.get('distribution', []),
  'dashboard_url': run.get('k6_runtime_config', {}).get('testRunDetails', ''),
}
print(json.dumps(summary, indent=2))
" > "$run_file"

  # Metrics list
  local metrics_file="$RESULTS_DIR/cloud-run-${run_id}-metrics.json"
  api_get "cloud/v5/test_runs/$run_id/metrics" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Keep only the metrics relevant for comparison
keep = {'http_req_duration','http_req_failed','http_reqs','sold_out_responses',
        'vus','vus_max','iterations','iteration_duration','claim_duration_ms'}
metrics = [m for m in d.get('value', []) if m['name'] in keep]
print(json.dumps({'run_id': $run_id, 'metrics': metrics}, indent=2))
" > "$metrics_file"

  echo "    Summary : $run_file"
  echo "    Metrics : $metrics_file"
  python3 -c "
import json
d = json.load(open('$run_file'))
status = 'PASSED' if d['result_status'] == 0 else 'FAILED (thresholds)'
print(f\"    Result  : {status}\")
print(f\"    Test    : {d['test_name']}  |  VUs: {d['vus']}  |  {d['started']} -> {d['ended']}\")
print(f\"    URL     : {d['dashboard_url']}\")
"
}

if [[ $# -ge 1 ]]; then
  download_run "$1"
else
  echo "=== Recent runs in project $PROJECT_ID ==="
  api_get "cloud/v5/projects/$PROJECT_ID/test_runs" | python3 -c "
import sys, json
d = json.load(sys.stdin)
runs = d.get('value', [])
if not runs:
    print('  No runs found.')
    sys.exit(0)
print(f'  {'ID':<12} {'Script':<25} {'Status':<10} {'Started':<30}')
print('  ' + '-'*80)
for r in sorted(runs, key=lambda x: x.get('started',''), reverse=True):
    status = {3:'finished', 2:'running', 4:'aborted'}.get(r.get('run_status'), str(r.get('run_status')))
    started = r.get('started', 'unknown')[:19]
    script = r.get('script', '')[:24] if isinstance(r.get('script'), str) else ''
    print(f\"  {r['id']:<12} {script:<25} {status:<10} {started}\")
"
  echo ""
  echo "Download a specific run: $0 <run_id>"
fi
