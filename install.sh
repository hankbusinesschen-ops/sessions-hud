#!/usr/bin/env bash
# One-shot installer for the sessions HUD stack.
#
#   ./install.sh             # build release, copy binaries, install daemon
#   ./install.sh uninstall   # remove binaries + unload daemon
#
# What lands on disk:
#   ~/.local/bin/ccw           -- claude PTY wrapper
#   ~/.local/bin/cxw           -- codex PTY wrapper
#   ~/.local/bin/sessionsd     -- monitoring daemon
#   ~/.local/bin/sessions-hud  -- SwiftUI HUD (launch manually)
#   ~/Library/LaunchAgents/com.sessionshud.daemon.plist
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LAUNCHD_SCRIPT="$REPO_ROOT/packaging/install-launchd.sh"

RUST_BINS=(ccw cxw sessionsd)
HUD_SRC="$REPO_ROOT/hud/.build/release/SessionsHUD"
HUD_DST="$BIN_DIR/sessions-hud"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

uninstall() {
    echo "→ unloading daemon"
    "$LAUNCHD_SCRIPT" uninstall || true

    echo "→ removing binaries"
    for b in "${RUST_BINS[@]}" sessions-hud; do
        rm -f "$BIN_DIR/$b"
    done
    green "uninstalled."
}

if [[ "${1:-}" == "uninstall" ]]; then
    uninstall
    exit 0
fi

mkdir -p "$BIN_DIR"

if ! command -v cargo >/dev/null 2>&1; then
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
fi
command -v cargo >/dev/null || { red "cargo not found — install rustup first"; exit 1; }
command -v swift >/dev/null || { red "swift not found — install Xcode command line tools"; exit 1; }

echo "→ building rust workspace (release)"
(cd "$REPO_ROOT" && cargo build --release --workspace)

echo "→ copying rust binaries to $BIN_DIR"
cp "$REPO_ROOT/target/release/ccw"       "$BIN_DIR/ccw"
cp "$REPO_ROOT/target/release/cxw"       "$BIN_DIR/cxw"
cp "$REPO_ROOT/target/release/sessionsd" "$BIN_DIR/sessionsd"

echo "→ building HUD (release)"
(cd "$REPO_ROOT/hud" && swift build -c release)
cp "$HUD_SRC" "$HUD_DST"
chmod +x "$HUD_DST"

echo "→ installing launchd daemon"
"$LAUNCHD_SCRIPT"

echo
green "installed:"
printf '  %s\n' \
    "$BIN_DIR/ccw" \
    "$BIN_DIR/cxw" \
    "$BIN_DIR/sessionsd" \
    "$BIN_DIR/sessions-hud"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo
        yellow "⚠  $BIN_DIR is not in your \$PATH. Add this to ~/.zshrc:"
        echo '    export PATH="$HOME/.local/bin:$PATH"'
        ;;
esac

HOOKS_FILE="$HOME/.claude/settings.json"
if [[ ! -f "$HOOKS_FILE" ]] || ! grep -q "sessionsd" "$HOOKS_FILE" 2>/dev/null; then
    echo
    yellow "⚠  Claude Code hooks not detected in $HOOKS_FILE"
    echo "   See README for the hook snippet to paste in."
fi

echo
green "ready. run 'sessions-hud' to open the HUD, 'ccw <name>' to launch a wrapped claude."
