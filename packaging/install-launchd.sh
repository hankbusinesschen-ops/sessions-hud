#!/usr/bin/env bash
# Install sessionsd as a per-user LaunchAgent so it starts at login.
#
# Usage:
#   ./packaging/install-launchd.sh            # build release + install + load
#   ./packaging/install-launchd.sh uninstall  # unload + remove plist
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.sessionshud.daemon"
PLIST_SRC="$REPO_ROOT/packaging/com.sessionshud.daemon.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/SessionsHUD"
BIN_DIR="$HOME/.local/bin"
SESSIONSD_BIN="$BIN_DIR/sessionsd"

uninstall() {
    if launchctl list | grep -q "$LABEL"; then
        launchctl unload "$PLIST_DST" 2>/dev/null || true
    fi
    rm -f "$PLIST_DST"
    echo "uninstalled $LABEL"
}

if [[ "${1:-}" == "uninstall" ]]; then
    uninstall
    exit 0
fi

mkdir -p "$LOG_DIR" "$BIN_DIR" "$(dirname "$PLIST_DST")"

echo "building sessionsd (release)…"
(cd "$REPO_ROOT" && cargo build --release -p sessionsd)
cp "$REPO_ROOT/target/release/sessionsd" "$SESSIONSD_BIN"

# Materialize plist with absolute paths substituted in.
sed \
    -e "s|__SESSIONSD_BIN__|$SESSIONSD_BIN|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    "$PLIST_SRC" > "$PLIST_DST"

# Reload so the new binary/plist takes effect.
if launchctl list | grep -q "$LABEL"; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
fi
launchctl load "$PLIST_DST"

echo "installed $LABEL"
echo "  plist: $PLIST_DST"
echo "  binary: $SESSIONSD_BIN"
echo "  logs: $LOG_DIR"
echo
echo "check: curl -s http://127.0.0.1:39501/health"
