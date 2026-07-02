#!/usr/bin/env bash
# Quick health check for Sessions HUD stack (ccw, sessionsd, hooks, statusline).
# Run from a terminal: ./scripts/check-sessions-hud-runtime.sh
set -euo pipefail

ok() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; }
warn() { echo "  ! $*"; }

echo "== Sessions HUD runtime check =="

# Binaries
for b in ccw sessionsd sessions-hud; do
  if command -v "$b" &>/dev/null; then
    ok "$b -> $(command -v "$b")"
  else
    fail "$b not in PATH (add ~/.local/bin to PATH?)"
  fi
done

# Optional: Codex wrapper
if command -v cxw &>/dev/null; then
  ok "cxw (optional) -> $(command -v cxw)"
else
  warn "cxw not in PATH (only needed for codex + cxw)"
fi

# Daemon
if curl -fsS "http://127.0.0.1:39501/health" &>/dev/null; then
  ok "sessionsd health at http://127.0.0.1:39501/health"
else
  fail "cannot reach sessionsd (launchctl kickstart -k gui/\$UID/com.sessionshud.daemon?)"
fi

# Launch agent (non-fatal: user may run sessionsd manually)
if launchctl list 2>/dev/null | grep -q com.sessionshud; then
  ok "LaunchAgent com.sessionshud present"
else
  warn "com.sessionshud not in launchctl list (daemon may be manual or different label)"
fi

# Claude Code hooks
SETTINGS="${HOME}/.claude/settings.json"
if [[ -f "$SETTINGS" ]]; then
  if grep -q "post-event.sh" "$SETTINGS" 2>/dev/null; then
    ok "~/.claude/settings.json references post-event.sh (hooks present)"
  else
    fail "~/.claude/settings.json has no post-event.sh — re-run install.sh or packaging/merge-hooks.sh"
  fi
else
  fail "missing $SETTINGS"
fi

# Statusline tee
STATUSLINE="${HOME}/.claude/statusline-command.sh"
if [[ -f "$STATUSLINE" ]]; then
  if grep -q "39501/hook/statusline" "$STATUSLINE" 2>/dev/null; then
    ok "~/.claude/statusline-command.sh includes sessionsd statusline curl"
  else
    warn "statusline script exists but no 39501/hook/statusline — ctx%/5h%/7d% may be missing in HUD"
  fi
else
  warn "no ~/.claude/statusline-command.sh — custom statusline or install packaging/patch-statusline.sh"
fi

echo "== done =="
