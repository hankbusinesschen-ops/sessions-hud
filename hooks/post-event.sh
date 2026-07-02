#!/bin/zsh
# Bridge a Claude Code hook into the Sessions HUD event spool.
# Usage: post-event.sh <EventName>
# Reads the hook payload from stdin, wraps it with local context (claude pid,
# tty, terminal app), and atomically drops one JSON file into the spool
# directory watched by Sessions HUD.app. Fails silently and never blocks
# Claude Code.
{
    zmodload zsh/datetime || exit 0
    EVENT="${${1:-unknown}//[\"\\\\]/}"
    SPOOL="${SESSIONSHUD_SPOOL:-$HOME/Library/Application Support/SessionsHUD/events}"
    mkdir -p "$SPOOL" || exit 0

    PAYLOAD="$(cat)"
    [[ -z "$PAYLOAD" ]] && PAYLOAD="{}"

    # Microsecond timestamp, zero-padded to 16 digits so lexicographic
    # filename order equals chronological order.
    TS_SEC="${EPOCHREALTIME%.*}"
    TS_FRAC="${EPOCHREALTIME#*.}000000"
    TS="$(printf '%016d' $(( TS_SEC * 1000000 + ${TS_FRAC[1,6]} )))"

    # Nearest claude-ish ancestor: Claude Code may exec hooks via `sh -c`,
    # so walk up a few levels before settling for the direct parent.
    PID=$PPID
    for _ in 1 2 3; do
        COMM="$(ps -o comm= -p $PID 2>/dev/null)"
        case "${COMM:t}" in
            (*claude*|*node*|*bun*) break ;;
        esac
        NEXT="$(ps -o ppid= -p $PID 2>/dev/null | tr -d ' ')"
        [[ -z "$NEXT" || "$NEXT" == "$PID" || "$NEXT" -le 1 ]] && break
        PID=$NEXT
    done

    # Controlling tty is inherited from claude even though hook stdio is piped.
    TTY_NAME="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')"
    if [[ -z "$TTY_NAME" || "$TTY_NAME" == "??" ]]; then TTY=""; else TTY="/dev/$TTY_NAME"; fi

    TERM_PROG="${TERM_PROGRAM//[\"\\\\]/}"

    TMP="$SPOOL/.tmp.$$"
    printf '{"v":1,"event":"%s","ts":%s,"pid":%d,"tty":"%s","term_program":"%s","payload":%s}\n' \
        "$EVENT" "$TS" "$PID" "$TTY" "$TERM_PROG" "$PAYLOAD" > "$TMP" \
        && mv -f "$TMP" "$SPOOL/$TS-$$.json"
} >/dev/null 2>&1
exit 0
