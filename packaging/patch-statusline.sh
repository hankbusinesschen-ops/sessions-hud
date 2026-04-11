#!/usr/bin/env bash
# Inject the sessionsd statusline tee into ~/.claude/statusline-command.sh.
# Uses sentinel comments so rerun is a no-op and uninstall can remove
# exactly the injected block.
set -euo pipefail

TARGET="$HOME/.claude/statusline-command.sh"
BEGIN="# >>> sessions-hud statusline tee >>>"
END="# <<< sessions-hud statusline tee <<<"

if [[ ! -f "$TARGET" ]]; then
    echo "statusline: $TARGET not found — skipping (optional)"
    exit 0
fi

if grep -qF "$BEGIN" "$TARGET"; then
    echo "statusline: already patched"
    exit 0
fi

# User may have pasted the snippet manually from README — detect by URL.
if grep -q '127.0.0.1:39501/hook/statusline' "$TARGET"; then
    echo "statusline: tee already present (pasted manually) — skipping"
    exit 0
fi

if ! grep -q 'input=$(cat)' "$TARGET"; then
    echo "statusline: could not find 'input=\$(cat)' anchor — skipping"
    exit 0
fi

cp "$TARGET" "$TARGET.bak.$(date +%s)"

python3 - "$TARGET" "$BEGIN" "$END" <<'PY'
import sys, pathlib
p, begin, end = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = p.read_text().splitlines(keepends=True)
out = []
inserted = False
block = [
    f"{begin}\n",
    "(printf '%s' \"$input\" | curl -s \\\n",
    "    --max-time 0.3 --connect-timeout 0.3 \\\n",
    "    -H 'Content-Type: application/json' -d @- \\\n",
    "    http://127.0.0.1:39501/hook/statusline >/dev/null 2>&1) &\n",
    f"{end}\n",
]
for line in lines:
    out.append(line)
    if not inserted and "input=$(cat)" in line:
        out.extend(block)
        inserted = True
p.write_text("".join(out))
print("statusline: patched")
PY
