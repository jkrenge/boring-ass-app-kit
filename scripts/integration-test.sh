#!/bin/zsh
# Runs the Swift integration test in the Simulator, or on this Mac, against the local Worker, then checks
# that the event, error, crash and feedback it sent all reached local D1.
# Needs `cd api && uv run pywrangler dev` running with ALLOW_UNATTESTED=true in api/.dev.vars.
# Usage: scripts/integration-test.sh ["iPhone 17 Pro" | macOS]
set -euo pipefail
cd "${0:A:h}/.."
API=http://127.0.0.1:8787
RUN=$(uuidgen)

[[ $(curl -s -o /dev/null -w '%{http_code}' $API/) == 404 ]] || { echo "Start the Worker first: cd api && uv run pywrangler dev"; exit 1; }

[[ ${1:-} == macOS ]] && DESTINATION="platform=macOS" || DESTINATION="platform=iOS Simulator,name=${1:-iPhone 17 Pro}"
TEST_RUNNER_BORINGKIT_API=$API TEST_RUNNER_BORINGKIT_RUN=$RUN xcodebuild test -quiet -scheme BoringKit -destination "$DESTINATION"

count() {
  (cd api && uv run pywrangler d1 execute boring-api --local --json --command "SELECT count(*) AS n FROM $1 WHERE $2 LIKE '%$RUN%'" 2>/dev/null) \
    | sed -n '/^\[/,$p' | python3 -c 'import sys, json; print(json.load(sys.stdin)[0]["results"][0]["n"])'
}

failed=0
for table column in events props errors message crashes report feedback message; do
  n=$(count $table $column)
  echo "$table: $n"
  (( n > 0 )) || failed=1
done
(( failed == 0 )) && echo "OK: everything reached the Worker" || { echo "FAILED: missing rows for run $RUN"; exit 1; }
