#!/usr/bin/env bash
# Paste this block near the top of ~/.claude/statusline-command.sh, right
# after `input=$(cat)`. It tees the raw statusline JSON into the Sessions HUD
# event spool so the HUD can surface ctx% / 5h% / 7d% / model name per session.
#
# Quota is state, not an event: the file name is fixed per session and
# atomically overwritten, so the spool never accumulates statusline files
# even when the HUD app isn't running.
#
# It's fire-and-forget: backgrounded, silent on failure. If anything goes
# wrong the terminal statusline keeps working unchanged.
#
# --- begin sessions-hud tee ---
(
    _shud_spool="$HOME/Library/Application Support/SessionsHUD/events"
    _shud_sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr -cd 'A-Za-z0-9._-')
    if [ -n "$_shud_sid" ]; then
        mkdir -p "$_shud_spool"
        printf '{"v":1,"event":"Statusline","ts":%s000000,"pid":0,"tty":"","term_program":"","payload":%s}\n' \
            "$(date +%s)" "$input" > "$_shud_spool/.tmp.statusline.$$" \
            && mv -f "$_shud_spool/.tmp.statusline.$$" "$_shud_spool/statusline-$_shud_sid.json"
    fi
) >/dev/null 2>&1 &
# --- end sessions-hud tee ---
