# Sessions HUD for Claude Code

> A floating macOS HUD that monitors every Claude Code / Codex CLI session
> you have open, surfaces approval prompts, displays live quota usage, and
> lets you spawn new sessions with one click.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Status: experimental](https://img.shields.io/badge/status-experimental-orange)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

<!-- Screen recording: add docs/media/hero.gif and uncomment the image tag. -->

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

### When is a session read-only vs injectable?

| How you started | In HUD list? | Approve / inject from HUD? |
|-------------------|--------------|----------------------------|
| Native `claude` / `codex` (no wrapper) | Yes — via Claude Code hooks | **No** — watch-only; use **Relaunch as ccw** or start `ccw <name>` in that repo |
| `ccw <name>` / `cxw <name>` / HUD `+` launcher | Yes | **Yes** — wrapper registers a PTY + unix socket; HUD posts to `/sessions/:id/input` |
| `ccw` but `sessionsd` is down | Row may be missing or wrapper unattached | Injection needs a healthy daemon on `127.0.0.1:39501` |

You need **three** things for a good “live + clickable” experience: **`sessionsd` running**, **Claude Code hooks** (so prompts, Stop, and transcript show up), and a **wrapper-backed** session for injection. Run [`scripts/check-sessions-hud-runtime.sh`](scripts/check-sessions-hud-runtime.sh) to verify binaries, health, hooks, and statusline — see [`docs/runtime-check.md`](docs/runtime-check.md).

### `ccw` wrapper defaults

The `ccw` binary wraps `claude` in a PTY and registers with `sessionsd`. By default it also passes `--dangerously-skip-permissions` to match a common local workflow (see `crates/cc/src/lib.rs`). To disable that behavior: set `CC_NO_SKIP_PERMISSIONS=1` or pass your own flags after `--`. This is separate from the HUD **launcher** permission modes (default / plan / auto edits / yolo).

## How it looks

Screenshots live in `docs/media/` when checked in. Until then, run the app and use **Mode A** (compact list) and **Mode B** (chat), or the **`+` launcher** popover.

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
on you, an approval banner appears above the input. For **wrapper-backed**
sessions, use **Interrupt (⌃C)** and **Enter ⏎** for quick TUI control, type
into the input box and **Send** for free text, and use the approval / question
buttons when shown. Native (read-only) sessions show a lock banner — start
`ccw` to enable controls.

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
         /hook/Stop                         │ Server-Sent Events
         /hook/statusline                   │ GET /events (+ JSONL
         transcript tail ~500ms            │  cache invalidation)
                 │                          │
                 │                          ▼
                                    ┌───────▼──────┐
                                    │  sessions-   │
                                    │  hud (Swift) │
                                    │  refetch     │
                                    │  /sessions   │
                                    └──────────────┘
```

Three components:

- **`ccw` / `cxw`** — portable-pty wrappers that own the real `claude` / `codex` child process. They register with the daemon on startup and expose a unix socket the daemon can write keystrokes into.
- **`sessionsd`** — a small axum HTTP server on `127.0.0.1:39501`. It aggregates wrapper registrations, Claude Code hook events, and statusline JSON into a single in-memory session registry, tails each session’s JSONL transcript (periodic, ~500 ms), and forwards input from the HUD back to the appropriate wrapper socket.
- **`sessions-hud`** — a SwiftUI app that subscribes to `/events` (SSE) for change notifications, refetches `GET /sessions` and `GET /sessions/:id` when sessions update, and POSTs to `/sessions/:id/input` for approvals and free text. A 10 s `/health` poll and SSE reconnect keep the connection honest after sleep/wake. (Settings also shows a local **Diagnostics** panel: hooks, statusline tee, `ccw` in `PATH`, daemon reachability.)

## Troubleshooting

From the repo root, run:

```bash
./scripts/check-sessions-hud-runtime.sh
```

**HUD is empty / no sessions show up.** Prefer `./scripts/check-sessions-hud-runtime.sh`, then:

```bash
launchctl list | grep com.sessionshud
curl -fsS http://127.0.0.1:39501/health
grep -q post-event.sh ~/.claude/settings.json && echo "hooks OK"
```

**`+` → Launch does nothing.** Automation permission. Check System Settings
→ Privacy & Security → Automation → Sessions HUD.

**`ctx% / 5h% / 7d%` rows never appear.** You need a custom
`~/.claude/statusline-command.sh` for the installer to patch; then
`packaging/patch-statusline.sh` (or re-run `./install.sh`) adds the tee to
`sessionsd`. Without a custom statusline file, the HUD has no way to read
Claude’s quota JSON.

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
- The daemon listens on `127.0.0.1` only — loopback, not network. **Any process on your machine running as your uid** can `POST` to `POST /sessions/:id/input` (inject keystrokes) or `POST /sessions/:id/terminate` (SIGTERM) if it knows a session id. The debug-only `POST /wrappers/:id/input` route is **disabled by default**; set `SESSIONSD_ENABLE_WRAPPER_INPUT=1` before starting `sessionsd` if you need it for E2E. Don't run this on a shared user account.
- `ccw` / `cxw` sit between your terminal and the real CLI. Every keystroke and every byte of output passes through the wrapper. Read the source (`crates/cc/src/`) if you care.

## Development

```bash
# Rust side
cargo build --workspace
cargo test --workspace

# Swift side
cd hud && swift build
```

Manual E2E checklist after feature work: [`docs/verification-checklist.md`](docs/verification-checklist.md).

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
