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

`install.sh` now wires up most things automatically:

- **Claude Code hooks** — idempotently merged into `~/.claude/settings.json` by `packaging/merge-hooks.sh`. If you already have other hooks, they're preserved.
- **Statusline tee** — if `~/.claude/statusline-command.sh` exists, the ctx%/5h%/7d% tee snippet is injected right after `input=$(cat)`. Skipped cleanly if you already pasted it manually or don't run a custom statusline.
- **Automation permission** — the HUD triggers macOS's Automation consent dialog on first launch so you approve it up-front instead of hitting a silent failure the first time you click `+` → Launch.

The only step you may still need to do manually:

### Add `~/.local/bin` to your PATH

If `install.sh` warned you about this, add it to `~/.zshrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then open a new terminal or `source ~/.zshrc`.

### If you denied the Automation prompt

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
