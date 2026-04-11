#!/usr/bin/env bash
# Merge Sessions HUD hook entries into ~/.claude/settings.json.
# Idempotent: re-running does nothing if hooks already point at REPO_ROOT.
#
#   merge-hooks.sh <REPO_ROOT>
set -euo pipefail

REPO_ROOT="${1:?usage: merge-hooks.sh <repo-root>}"
SETTINGS="$HOME/.claude/settings.json"
SENTINEL="hooks/post-event.sh"

mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

python3 - "$SETTINGS" "$REPO_ROOT" "$SENTINEL" <<'PY'
import json, sys, pathlib
settings_path, repo_root, sentinel = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(settings_path)
try:
    data = json.loads(p.read_text())
except json.JSONDecodeError as e:
    sys.exit(f"settings.json is not valid JSON ({e}); refusing to merge")

hooks = data.setdefault("hooks", {})
events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop"]
script = f"{repo_root}/hooks/post-event.sh"

def already_wired(entry_list):
    for block in entry_list or []:
        for h in block.get("hooks", []) or []:
            if sentinel in h.get("command", ""):
                return True
    return False

changed = False
for ev in events:
    existing = hooks.get(ev)
    if already_wired(existing):
        continue
    new_block = {"hooks": [{"type": "command", "command": f"{script} {ev}"}]}
    hooks[ev] = (existing or []) + [new_block]
    changed = True

if changed:
    p.write_text(json.dumps(data, indent=2) + "\n")
    print("hooks: merged")
else:
    print("hooks: already wired")
PY
