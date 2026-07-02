#!/usr/bin/env bash
# One-shot installer for Sessions HUD.
#
#   ./install.sh             # build "Sessions HUD.app", install, wire hooks, open
#   ./install.sh uninstall   # remove the app + hooks (+ legacy daemon bits)
#
# What lands on disk:
#   /Applications/Sessions HUD.app            (or ~/Applications as fallback)
#   ~/Library/Application Support/SessionsHUD/post-event.sh
#   hook entries in ~/.claude/settings.json
#   quota tee in ~/.claude/statusline-command.sh (only if that file exists)
#
# Also migrates away from the pre-2026-07 architecture: unloads the old
# sessionsd launchd daemon and removes the old ~/.local/bin binaries.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Sessions HUD.app"
DIST_APP="$REPO_ROOT/dist/$APP_NAME"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

installed_app() {
    for dir in "/Applications" "$HOME/Applications"; do
        if [[ -d "$dir/$APP_NAME" ]]; then
            echo "$dir/$APP_NAME"
            return
        fi
    done
}

# Retire the pre-refactor stack: launchd daemon, PTY wrappers, CLI HUD.
migrate_legacy() {
    if launchctl print "gui/$(id -u)/com.sessionshud.daemon" &>/dev/null; then
        echo "→ unloading legacy sessionsd daemon"
        launchctl bootout "gui/$(id -u)/com.sessionshud.daemon" || true
    fi
    rm -f "$HOME/Library/LaunchAgents/com.sessionshud.daemon.plist"
    rm -f "$HOME/.local/bin/ccw" "$HOME/.local/bin/cxw" \
          "$HOME/.local/bin/sessionsd" "$HOME/.local/bin/sessions-hud"
    rm -rf "$HOME/Library/Logs/SessionsHUD"
}

uninstall() {
    local app
    app="$(installed_app || true)"
    if [[ -n "${app:-}" ]]; then
        echo "→ removing hooks + statusline tee"
        "$app/Contents/MacOS/SessionsHUD" --uninstall-hooks || true
    fi
    for dir in "/Applications" "$HOME/Applications"; do
        if [[ -d "$dir/$APP_NAME" ]]; then
            echo "→ removing $dir/$APP_NAME"
            rm -rf "$dir/$APP_NAME"
        fi
    done
    echo "→ cleaning legacy daemon bits"
    migrate_legacy
    yellow "note: ~/Library/Application Support/SessionsHUD (事件與狀態) 保留；"
    yellow "      不需要時可自行刪除。"
    green "uninstalled."
}

if [[ "${1:-}" == "uninstall" ]]; then
    uninstall
    exit 0
fi

command -v swift >/dev/null || { red "swift not found — install Xcode command line tools"; exit 1; }

"$REPO_ROOT/scripts/make-app.sh"

# rm before ditto: ditto merges into an existing bundle, which would leave
# files from older layouts inside the app.
APP_DST="/Applications/$APP_NAME"
if rm -rf "$APP_DST" 2>/dev/null && ditto "$DIST_APP" "$APP_DST" 2>/dev/null; then
    :
else
    yellow "⚠ 無法寫入 /Applications，改裝到 ~/Applications"
    APP_DST="$HOME/Applications/$APP_NAME"
    mkdir -p "$HOME/Applications"
    rm -rf "$APP_DST"
    ditto "$DIST_APP" "$APP_DST"
fi
echo "→ installed: $APP_DST"

# Hooks BEFORE legacy teardown: if this step fails, the old setup is still
# intact instead of leaving a half-migrated machine.
echo "→ wiring Claude Code hooks + statusline tee"
"$APP_DST/Contents/MacOS/SessionsHUD" --install-hooks

echo "→ cleaning legacy install (daemon / wrappers)"
migrate_legacy

echo
green "done. 開啟中…（之後可從 Launchpad / Spotlight 搜「Sessions HUD」）"
open "$APP_DST"
