#!/usr/bin/env bash
# Bridge a Claude Code hook into the sessionsd daemon.
# Usage: post-event.sh <EventName>
# Reads the hook payload from stdin and POSTs it to the daemon.
# Fails silently — never block Claude Code on a daemon outage.
set -uo pipefail

EVENT="${1:-unknown}"
DAEMON_URL="${SESSIONSD_URL:-http://127.0.0.1:39501}"

# Drain stdin into a variable so we can pass it to curl with a short timeout.
PAYLOAD="$(cat)"

curl --silent --show-error --fail \
    --max-time 1 \
    --connect-timeout 1 \
    -H 'Content-Type: application/json' \
    -X POST \
    --data "$PAYLOAD" \
    "${DAEMON_URL}/hook/${EVENT}" \
    >/dev/null 2>&1 || true

exit 0
