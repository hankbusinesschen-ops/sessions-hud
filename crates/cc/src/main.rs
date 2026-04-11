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
use serde::{Deserialize, Serialize};
use signal_hook::{consts::SIGWINCH, iterator::Signals};
use std::io::{IsTerminal, Read, Write};
use std::os::unix::net::UnixListener;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

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

#[derive(Serialize)]
struct RegisterRequest<'a> {
    name: &'a str,
    cwd: &'a str,
    pid: u32,
    tty: Option<String>,
    term_program: Option<String>,
}

/// Best-effort lookup of the controlling tty on stdin — used by the HUD's
/// "Open in Terminal" button to focus the right window via AppleScript.
fn stdin_tty() -> Option<String> {
    use std::ffi::CStr;
    let ptr = unsafe { libc::ttyname(0) };
    if ptr.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned();
    Some(s)
}

#[derive(Deserialize)]
struct RegisterResponse {
    wrapper_id: String,
    socket_path: String,
}

/// Registration info returned by the daemon — wrapper_id + the unix socket
/// the wrapper should bind for HUD input injection.
struct Registration {
    wrapper_id: String,
    socket_path: String,
}

fn daemon_url() -> String {
    std::env::var("SESSIONSD_URL").unwrap_or_else(|_| "http://127.0.0.1:39501".into())
}

/// Try to register with sessionsd. Soft-fails: if the daemon isn't up, cc
/// still works as a transparent passthrough — you just don't get the named
/// session in the HUD.
fn register_with_daemon(name: &str, cwd: &str) -> Option<Registration> {
    let req = RegisterRequest {
        name,
        cwd,
        pid: std::process::id(),
        tty: stdin_tty(),
        term_program: std::env::var("TERM_PROGRAM").ok(),
    };
    let url = format!("{}/register", daemon_url());
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_millis(500))
        .timeout(Duration::from_millis(1000))
        .build();
    match agent.post(&url).send_json(serde_json::to_value(&req).ok()?) {
        Ok(resp) => match resp.into_json::<RegisterResponse>() {
            Ok(r) => Some(Registration {
                wrapper_id: r.wrapper_id,
                socket_path: r.socket_path,
            }),
            Err(e) => {
                eprintln!("cc: register decode failed: {e}");
                None
            }
        },
        Err(e) => {
            eprintln!("cc: sessionsd not reachable ({e}) — running unattached");
            None
        }
    }
}

/// Bind a unix domain socket the daemon can connect to in order to inject
/// HUD-sourced keystrokes into our PTY. Each accepted connection gets a
/// reader thread that drains bytes and pushes them through `tx` to the
/// single pty-writer thread.
fn start_inject_listener(path: String, tx: mpsc::Sender<Vec<u8>>) -> Result<()> {
    // Clean up any stale socket left behind by an ungracefully-killed cc.
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)
        .with_context(|| format!("bind unix socket {path}"))?;
    // Only the current uid should be able to connect (the daemon runs as us).
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));

    thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(mut conn) = conn else { continue };
            let tx = tx.clone();
            thread::spawn(move || {
                let mut buf = [0u8; 4096];
                loop {
                    match conn.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            if tx.send(buf[..n].to_vec()).is_err() {
                                return;
                            }
                        }
                        Err(_) => break,
                    }
                }
            });
        }
    });
    Ok(())
}

fn unregister_from_daemon(wrapper_id: &str) {
    let url = format!("{}/wrappers/{}", daemon_url(), wrapper_id);
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_millis(500))
        .timeout(Duration::from_millis(1000))
        .build();
    let _ = agent.delete(&url).call();
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

    // Register with sessionsd so the HUD can show the user-chosen name
    // instead of the cwd basename. Soft-fails if the daemon is down.
    let cwd_str = std::env::current_dir()
        .ok()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();
    let registration = register_with_daemon(&name, &cwd_str);

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
    // When wrapping `claude`, default to --dangerously-skip-permissions to
    // match the user's day-to-day workflow. Escape hatches:
    //   - user already passed the flag in `-- <args>`
    //   - CC_NO_SKIP_PERMISSIONS=1
    //   - non-claude target (bash / cat / codex stubs for testing)
    {
        let is_claude = target == "claude";
        let user_has_flag = extra_args.iter().any(|a| a == "--dangerously-skip-permissions");
        let opt_out = std::env::var("CC_NO_SKIP_PERMISSIONS").ok().as_deref() == Some("1");
        if is_claude && !user_has_flag && !opt_out {
            cmd.arg("--dangerously-skip-permissions");
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        cmd.cwd(cwd);
    }
    // Use vars_os so a mangled/non-UTF8 env var (e.g. when invoked from a
    // subshell that misencoded a parent $PWD) doesn't panic the wrapper.
    for (k, v) in std::env::vars_os() {
        cmd.env(k, v);
    }
    cmd.env("CC_WRAPPER_NAME", &name);
    if let Some(ref reg) = registration {
        cmd.env("CC_WRAPPER_ID", &reg.wrapper_id);
    }

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

    // All PTY stdin sources (keyboard + HUD inject socket) funnel through one
    // mpsc channel into a single writer thread. portable-pty's Writer is
    // `Box<dyn Write + Send>` and can only have one owner, so sharing via a
    // channel is simpler than wrapping it in a mutex.
    let (tx, rx) = mpsc::channel::<Vec<u8>>();

    // Writer thread — sole owner of the PTY master writer.
    thread::spawn(move || {
        while let Ok(bytes) = rx.recv() {
            if writer.write_all(&bytes).is_err() {
                break;
            }
            let _ = writer.flush();
        }
    });

    // Start the HUD inject listener if we successfully registered. We do this
    // before flipping into raw mode so bind errors surface cleanly.
    if let Some(ref reg) = registration {
        if let Err(e) = start_inject_listener(reg.socket_path.clone(), tx.clone()) {
            eprintln!("cc: failed to bind inject socket: {e}");
        }
    }

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

    // Thread: stdin → channel (keyboard path).
    {
        let tx = tx.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            let mut stdin = std::io::stdin();
            loop {
                match stdin.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        if tx.send(buf[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });
    }
    // Main thread no longer sends on tx; drop so the writer can shut down
    // cleanly once stdin + any inject-listener Senders are gone.
    drop(tx);

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

    if let Some(ref reg) = registration {
        unregister_from_daemon(&reg.wrapper_id);
        let _ = std::fs::remove_file(&reg.socket_path);
    }

    let code = if status.success() { 0 } else { status.exit_code() as i32 };
    std::process::exit(code);
}
