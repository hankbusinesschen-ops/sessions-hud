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

# Debug: dump Notification payloads so we can answer "can we tell permission
# requests apart from other notifications?" (risk #5 in the design doc).
# Remove once we know the answer.
if [ "$EVENT" = "Notification" ]; then
    DEBUG_LOG="${SESSIONSD_DEBUG_LOG:-/tmp/sessionsd-notification.log}"
    {
        echo "--- $(date -Iseconds) ---"
        echo "$PAYLOAD"
        echo
    } >> "$DEBUG_LOG" 2>/dev/null || true
fi

# If we were spawned under a `cc` PTY wrapper, propagate its id so the
# daemon can map session_id ↔ wrapper and use the user's chosen name.
WRAPPER_HEADER=()
if [ -n "${CC_WRAPPER_ID:-}" ]; then
    WRAPPER_HEADER=(-H "X-Cc-Wrapper-Id: ${CC_WRAPPER_ID}")
fi

curl --silent --show-error --fail \
    --max-time 1 \
    --connect-timeout 1 \
    -H 'Content-Type: application/json' \
    ${WRAPPER_HEADER[@]+"${WRAPPER_HEADER[@]}"} \
    -X POST \
    --data "$PAYLOAD" \
    "${DAEMON_URL}/hook/${EVENT}" \
    >/dev/null 2>&1 || true

exit 0
