# Sessions HUD for Claude Code

> A floating macOS HUD that monitors every Claude Code / Codex CLI session
> you have open, surfaces approval prompts, displays live quota usage, and
> lets you spawn new sessions with one click.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Status: experimental](https://img.shields.io/badge/status-experimental-orange)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

<!-- TODO: record docs/media/hero.gif (20s: open HUD → approve permission → + button launch → new session appears) -->
<p align="center">
  <img src="docs/media/hero.gif" alt="Sessions HUD demo" width="640"/>
</p>

## What it is

If you run Claude Code as your main coding loop, you probably have three or
four `claude` sessions open across different repos at the same time. They
sprawl across terminal tabs and windows. You miss permission prompts buried
under other work. You can't tell at a glance which session is about to hit
its 5-hour rate limit. Switching between them means hunting through tab
strips.

Sessions HUD is a small floating window that sits on top of your desktop
and shows every live `claude` / `codex` session in one place — grouped by
git repo, with status, quota usage, and the full chat history one click
away. When a session needs approval, you answer from the HUD. When you want
a new session, you click `+`.

## Features

- **Live session list**, grouped by git repo, with per-session status
- **Full chat view** for any selected session — messages, tool calls, approval banners
- **Answer approval prompts** (tool permissions, plan-mode approvals, `AskUserQuestion`) directly from the HUD — no tabbing back to the terminal
- **Live quota display** — `ctx% / 5h% / 7d%` per session, mirroring Claude Code's own statusline, threshold-colored (orange at 60%, red at 80%)
- **Spawn new sessions** from the HUD — pick a recent project root, pick a permission mode (default / plan / auto edits / yolo), click Launch
- Works with native `claude` / `codex` CLIs **and** with the optional `ccw` / `cxw` PTY wrappers. Wrapper-backed sessions are injectable (you can answer prompts and send free text); native sessions are read-only

## How it looks

<!-- TODO: capture three screenshots into docs/media/ -->

| Compact list | Chat view | Launcher |
|:---:|:---:|:---:|
| ![list](docs/media/list.png) | ![chat](docs/media/chat.png) | ![launcher](docs/media/launcher.png) |

## Requirements

- **macOS 13 (Ventura) or later** — Apple Silicon or Intel
- **Claude Code CLI** installed and working (`claude --version`)
- **Rust** via [rustup](https://rustup.rs) — needed to build the wrapper + daemon
- **Xcode Command Line Tools** (`xcode-select --install`) — needed to build the HUD with `swift`
- Optional: **Codex CLI** if you want the `cxw` wrapper
- Optional: **Terminal.app** or **iTerm2** — needed by the `+` launcher to spawn new sessions (Terminal.app is preinstalled)

## Install

```bash
git clone https://github.com/hankbusinesschen-ops/sessions-hud.git
cd sessions-hud
./install.sh
```

`install.sh` builds the Rust workspace and the Swift HUD in release mode,
then drops the following on disk:

- `~/.local/bin/ccw` — claude PTY wrapper
- `~/.local/bin/cxw` — codex PTY wrapper
- `~/.local/bin/sessionsd` — monitor daemon
- `~/.local/bin/sessions-hud` — SwiftUI HUD app
- `~/Library/LaunchAgents/com.sessionshud.daemon.plist` — launchd entry that keeps the daemon running
- `~/Library/Logs/SessionsHUD/sessionsd.{out,err}.log` — daemon logs

To remove everything:

```bash
./install.sh uninstall
```

## Post-install setup

`install.sh` installs the binaries and the launchd daemon, but three more
pieces have to be wired up by hand. None of them are optional if you want
the full experience.

### 1. Add `~/.local/bin` to your PATH

If `install.sh` warned you about this, add it to `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then open a new terminal or `source ~/.zshrc`.

### 2. Wire up Claude Code hooks (required for live session tracking)

The daemon learns about sessions from Claude Code's hook system. Open
`~/.claude/settings.json` and merge in the following block. **Replace
`/PATH/TO/sessions-hud`** with the absolute path to your clone (e.g.
`/Users/you/code/sessions-hud`).

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "/PATH/TO/sessions-hud/hooks/post-event.sh SessionStart" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/PATH/TO/sessions-hud/hooks/post-event.sh UserPromptSubmit" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "/PATH/TO/sessions-hud/hooks/post-event.sh Notification" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "/PATH/TO/sessions-hud/hooks/post-event.sh Stop" }] }]
  }
}
```

Each hook POSTs a small JSON blob to `http://127.0.0.1:39501/hook/<event>`.
The script is fire-and-forget — if the daemon is down, Claude Code keeps
working and you just don't see the session in the HUD.

### 3. Patch your statusline for quota display (optional but recommended)

If you already use Claude Code's custom statusline (`~/.claude/statusline-command.sh`),
paste the block below near the top of that file, right after `input=$(cat)`.
It tees the raw statusline JSON to the daemon so the HUD can show `ctx% /
5h% / 7d%` per session.

```bash
(printf '%s' "$input" | curl -s \
    --max-time 0.3 --connect-timeout 0.3 \
    -H 'Content-Type: application/json' -d @- \
    http://127.0.0.1:39501/hook/statusline >/dev/null 2>&1) &
```

It's capped at 300ms, backgrounded, silent on failure. If sessionsd is down
the statusline keeps working unchanged. Without this patch the HUD still
works — quota rows just stay blank.

Also available as a file: `packaging/statusline-snippet.sh`.

### 4. Grant Automation permission (required for the `+` launcher)

The first time you click `+` → Launch in the HUD, macOS pops up a dialog
asking whether to allow Sessions HUD to control Terminal.app (or iTerm2).
Click **OK**. If you mis-click Deny:

> System Settings → Privacy & Security → Automation → Sessions HUD → enable Terminal / iTerm

## Usage

### Launching sessions

Three ways to start a session that shows up in the HUD:

1. **Click `+` in the HUD** → pick a flavor (ccw / cxw), pick a permission mode, pick a project root (recent list or file picker), click Launch. This is the smooth path.
2. **Run `ccw <name>` or `cxw <name>`** in any terminal. These are thin PTY wrappers around `claude` / `codex` that let the HUD inject keystrokes, so approvals work.
3. **Run native `claude` or `codex`** as usual. It shows up in the HUD read-only — you'll see status and quota but the approval buttons stay greyed out. Re-launch via `ccw <name>` to enable injection.

### Compact list (Mode A)

The default HUD view. One row per session, grouped by git repo. Each row
shows the session name, status, last-activity time, and (if the statusline
patch is installed) a `ctx% / 5h% / 7d%` line. Click a row to drop into
Mode B.

### Chat view (Mode B)

Full message history for the selected session. When the session is waiting
on you, an approval banner appears above the input. Type into the input
box and hit Enter to inject free text (wrapper-backed sessions only).

### The `+` launcher

- **Flavor** — `ccw` (claude) or `cxw` (codex). The mode picker is hidden for `cxw` because codex has no equivalent flag in v1.
- **Mode** — see below.
- **Name** — auto-derived from the chosen directory; edit if you want.
- **Recent roots** — the six most recently active git repo roots. Click one to fill the cwd field.
- **Choose directory** — open a file picker if the repo you want isn't in the recent list.

### Permission modes

- **default** — standard Claude Code permissions. Tools prompt before running.
- **plan** — plan mode. Claude drafts a plan and waits for your approval before touching anything.
- **auto edits** — file edits go through without asking; commands still prompt.
- **yolo** — `--permission-mode bypassPermissions`. **Skips all tool permission prompts.** Only use in disposable repos or sandboxes you already trust.

## Architecture

```
         ┌───────────────┐
         │ claude / codex│
         └───────┬───────┘
                 │ stdin/stdout via PTY
         ┌───────▼──────┐
         │  ccw / cxw   │──── /register ────┐
         │  (wrapper)   │                   │
         └───────┬──────┘                   │
                 │ unix socket              │
                 │                          ▼
   HUD → /sessions/:id/input        ┌───────────────┐
                                    │   sessionsd   │
         Claude Code hooks ───────▶ │  (launchd,    │
         /hook/SessionStart         │   port 39501) │
         /hook/UserPromptSubmit     └───────┬───────┘
         /hook/Notification                 │
         /hook/Stop                         │ HTTP poll (1s)
         /hook/statusline                   │
                                    ┌───────▼──────┐
                                    │  sessions-   │
                                    │  hud (Swift) │
                                    └──────────────┘
```

Three components:

- **`ccw` / `cxw`** — portable-pty wrappers that own the real `claude` / `codex` child process. They register with the daemon on startup and expose a unix socket the daemon can write keystrokes into.
- **`sessionsd`** — a small axum HTTP server on `127.0.0.1:39501`. It aggregates wrapper registrations, Claude Code hook events, and statusline JSON into a single in-memory session registry, and forwards input from the HUD back to the appropriate wrapper socket.
- **`sessions-hud`** — a SwiftUI app that polls the daemon once per second, renders the compact list and chat views, and POSTs input / approval responses.

## Troubleshooting

**HUD is empty / no sessions show up.** Check that the daemon is running
and the hooks are wired up:

```bash
launchctl list | grep sessionsd
curl http://127.0.0.1:39501/health
grep sessionsd ~/.claude/settings.json
```

**`+` → Launch does nothing.** Automation permission. Check System Settings
→ Privacy & Security → Automation → Sessions HUD.

**`ctx% / 5h% / 7d%` rows never appear.** The statusline tee block isn't
installed. See post-install step 3.

**Approval buttons are greyed out.** That session was launched with native
`claude`, not `ccw`. Native sessions are read-only — re-launch via `ccw
<name>` to enable injection.

**Daemon logs.** `~/Library/Logs/SessionsHUD/sessionsd.err.log` has the
interesting stuff; `.out.log` is usually quiet.

**Port 39501 already in use.** Probably a stale daemon from a previous
install:

```bash
lsof -ti:39501 | xargs kill
launchctl kickstart -k gui/$UID/com.sessionshud.daemon
```

## Safety

- The `yolo` permission mode passes `--permission-mode bypassPermissions` to claude. It **skips all tool permission prompts**. Only use it in disposable repos or sandboxes.
- The daemon listens on `127.0.0.1` only — loopback, not network. Any process on your machine running as your uid can POST to it. Don't run this on a shared user account.
- `ccw` / `cxw` sit between your terminal and the real CLI. Every keystroke and every byte of output passes through the wrapper. Read the source (`crates/cc/src/`) if you care.

## Development

```bash
# Rust side
cargo build --workspace
cargo test --workspace

# Swift side
cd hud && swift build
```

Layout:

- `crates/sessionsd/` — daemon
- `crates/cc/` — `ccw` + `cxw` wrapper binaries, shared PTY code
- `hud/Sources/SessionsHUD/` — SwiftUI app
- `hooks/` — hook bridge script invoked by Claude Code
- `packaging/` — launchd plist, install helpers, statusline snippet

## License

MIT — see [`LICENSE`](LICENSE).

## Acknowledgements

Built for and around [Claude Code](https://claude.com/claude-code) by
Anthropic. Not affiliated.
