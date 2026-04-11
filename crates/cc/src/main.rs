// `cc` — PTY wrapper for `claude` (and later `codex` via `cx`).
//
// Phase 2a: pure passthrough. Spawns claude in a PTY, forwards stdin/stdout
// transparently, and resizes the PTY when the host terminal resizes. No
// daemon integration yet — that lands in Phase 2b.
//
// Usage:
//     cc <session-name> [-- claude-args...]
//
// The session name is currently informational; in 2b it will be sent to
// sessionsd at /register so the HUD can show it instead of the cwd basename.

use anyhow::{Context, Result};
use crossterm::terminal;
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use signal_hook::{consts::SIGWINCH, iterator::Signals};
use std::io::{IsTerminal, Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;

/// Restores cooked mode on drop, no matter how we exit. A no-op when stdin
/// isn't a tty (e.g. piped input, or running under Claude Code's Bash tool).
struct RawModeGuard {
    enabled: bool,
}
impl RawModeGuard {
    fn enable_if_tty() -> Result<Self> {
        if std::io::stdin().is_terminal() {
            terminal::enable_raw_mode().context("enable raw mode")?;
            Ok(Self { enabled: true })
        } else {
            Ok(Self { enabled: false })
        }
    }
}
impl Drop for RawModeGuard {
    fn drop(&mut self) {
        if self.enabled {
            let _ = terminal::disable_raw_mode();
        }
    }
}

fn parse_args() -> (String, Vec<String>) {
    let mut args = std::env::args().skip(1);
    let name = args.next().unwrap_or_else(|| "unnamed".into());
    // Everything after `--` is forwarded as additional claude args.
    let mut rest: Vec<String> = args.collect();
    if let Some(pos) = rest.iter().position(|a| a == "--") {
        rest.remove(pos);
    }
    (name, rest)
}

fn main() -> Result<()> {
    let (name, extra_args) = parse_args();

    // Resolve target program. Override with $CC_WRAPPER_TARGET for testing.
    let target = std::env::var("CC_WRAPPER_TARGET").unwrap_or_else(|_| "claude".to_string());

    // Detect host terminal size; fall back to 80x24 if we're not on a tty.
    let (cols, rows) = terminal::size().unwrap_or((80, 24));
    let initial = PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    };

    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(initial)
        .context("openpty")?;

    // Build the child command with current cwd + inherited env + a marker
    // env var so the SessionStart hook (Phase 2b) knows which wrapper this is.
    let mut cmd = CommandBuilder::new(&target);
    for a in &extra_args {
        cmd.arg(a);
    }
    if let Ok(cwd) = std::env::current_dir() {
        cmd.cwd(cwd);
    }
    for (k, v) in std::env::vars() {
        cmd.env(k, v);
    }
    cmd.env("CC_WRAPPER_NAME", &name);

    let mut child = pair
        .slave
        .spawn_command(cmd)
        .with_context(|| format!("spawn {target}"))?;
    drop(pair.slave);

    // Take ownership of master before wrapping it (resize needs the master,
    // and `take_writer` is &mut, so we sequence both before sharing).
    let master = pair.master;
    let mut reader = master
        .try_clone_reader()
        .context("clone pty reader")?;
    let mut writer = master
        .take_writer()
        .context("take pty writer")?;
    let master = Arc::new(Mutex::new(master));

    // Now that the PTY is wired up, flip the host terminal into raw mode so
    // keystrokes flow through verbatim (Ctrl-C becomes 0x03 in stdin, etc.).
    let _raw = RawModeGuard::enable_if_tty()?;

    // Thread: pty master → stdout
    let out_thread = thread::spawn(move || {
        let mut buf = [0u8; 4096];
        let mut stdout = std::io::stdout();
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if stdout.write_all(&buf[..n]).is_err() {
                        break;
                    }
                    let _ = stdout.flush();
                }
                Err(_) => break,
            }
        }
    });

    // Thread: stdin → pty master
    // This thread will be left dangling on stdin.read() when the child exits;
    // we exit the process explicitly below so it gets reaped by the OS.
    thread::spawn(move || {
        let mut buf = [0u8; 4096];
        let mut stdin = std::io::stdin();
        loop {
            match stdin.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if writer.write_all(&buf[..n]).is_err() {
                        break;
                    }
                    let _ = writer.flush();
                }
                Err(_) => break,
            }
        }
    });

    // Thread: SIGWINCH → resize PTY to match the host terminal.
    {
        let master = Arc::clone(&master);
        thread::spawn(move || {
            let mut signals = match Signals::new([SIGWINCH]) {
                Ok(s) => s,
                Err(_) => return,
            };
            for _ in signals.forever() {
                if let Ok((cols, rows)) = terminal::size() {
                    if let Ok(m) = master.lock() {
                        let _ = m.resize(PtySize {
                            rows,
                            cols,
                            pixel_width: 0,
                            pixel_height: 0,
                        });
                    }
                }
            }
        });
    }

    let status = child.wait().context("child wait")?;
    drop(_raw);
    let _ = out_thread.join();

    let code = if status.success() { 0 } else { status.exit_code() as i32 };
    std::process::exit(code);
}
