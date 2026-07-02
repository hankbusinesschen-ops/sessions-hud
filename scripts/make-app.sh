#!/usr/bin/env bash
# Build the release binary and assemble "Sessions HUD.app".
#
#   scripts/make-app.sh [output-dir]   # default: <repo>/dist
#
# The bundle carries hooks/post-event.sh in Resources so the installer (and
# the in-app "install hooks" button) can copy it to a stable location.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/dist}"
APP="$OUT_DIR/Sessions HUD.app"

echo "→ building HUD (release)"
(cd "$REPO_ROOT/hud" && swift build -c release)

echo "→ assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO_ROOT/hud/.build/release/SessionsHUD" "$APP/Contents/MacOS/SessionsHUD"
cp "$REPO_ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO_ROOT/hooks/post-event.sh" "$APP/Contents/Resources/post-event.sh"
chmod +x "$APP/Contents/MacOS/SessionsHUD" "$APP/Contents/Resources/post-event.sh"

# Ad-hoc signature: enough for local use; TCC may re-prompt Automation
# consent after rebuilds because the CDHash changes.
codesign --force --sign - "$APP"

echo "→ built: $APP"
