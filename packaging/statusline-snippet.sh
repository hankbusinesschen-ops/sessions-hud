#!/usr/bin/env bash
# Paste this block near the top of ~/.claude/statusline-command.sh, right
# after `input=$(cat)`. It tees the raw statusline JSON to sessionsd so the
# HUD can surface ctx% / 5h% / 7d% / model name per session.
#
# It's fire-and-forget: capped at 300ms, backgrounded, silent on failure.
# If sessionsd is down the terminal statusline keeps working unchanged.
#
# --- begin tee ---
(printf '%s' "$input" | curl -s \
    --max-time 0.3 --connect-timeout 0.3 \
    -H 'Content-Type: application/json' -d @- \
    http://127.0.0.1:39501/hook/statusline >/dev/null 2>&1) &
# --- end tee ---
