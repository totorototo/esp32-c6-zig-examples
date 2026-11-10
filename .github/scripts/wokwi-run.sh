#!/usr/bin/env bash
# Runs one sample in Wokwi and checks its serial log.
#
#   wokwi-run.sh <sample dir> <timeout ms> <expected text>
#
# Needs WOKWI_CLI_TOKEN and wokwi-cli on PATH. Retries when Wokwi's service refuses the
# connection (503, dropped websocket), which happens when runs start back to back.
set -uo pipefail

dir=$1
timeout=$2
expect=$3
log=$(mktemp)

for attempt in 1 2 3; do
    (cd "$dir" && wokwi-cli --timeout "$timeout" --expect-text "$expect" \
        --fail-text "FAIL" .) 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    if ! grep -q "Service Unavailable\|code 1006\|closed before the connection" "$log"; then
        break
    fi
    echo "::warning::Wokwi service error, retrying ($attempt/3)"
    sleep $((attempt * 15))
done

# The free plan's monthly CI minutes ran out: nothing was simulated, so this says nothing
# about the firmware. Warn and pass, so builds and host tests still gate the job.
if grep -q "CI minute quota" "$log"; then
    echo "::warning::$dir: not simulated, Wokwi CI minute quota used up for this month"
    exit 0
fi

if [ "$rc" -ne 0 ]; then
    echo "::error::$dir: did not print \`$expect\` (wokwi-cli exit $rc)"
fi
exit "$rc"
