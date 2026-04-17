use anyhow::Result;
use axum::{
    body::Bytes,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::sse::{Event, KeepAlive, Sse},
    response::{IntoResponse, Json},
    routing::{delete, get, post},
    Router,
};
use chrono::{DateTime, Utc};
use futures::stream::Stream;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::fs::File;
use tokio::io::{AsyncBufReadExt, AsyncSeekExt, BufReader, SeekFrom};
use tokio::sync::broadcast;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt;

const LISTEN_ADDR: &str = "127.0.0.1:39501";
const TAIL_INTERVAL: Duration = Duration::from_millis(500);
const MAX_MESSAGES_PER_SESSION: usize = 500;
const WRAPPER_PRUNE_INTERVAL: Duration = Duration::from_secs(5);
/// How often to sweep stale native (hook-only) sessions that never got a
/// SessionEnd — either because the user SIGKILLed claude or because the
/// hook missed.
const NATIVE_SWEEP_INTERVAL: Duration = Duration::from_secs(300); // 5 min
/// Default age (in hours) after which a quiet native session is considered
/// stale and eligible for sweeping. Overridable via
/// `SESSIONSD_NATIVE_STALE_HOURS` for testing / aggressive setups.
const DEFAULT_NATIVE_STALE_HOURS: f64 = 2.0;
/// Max bytes we buffer per session while waiting for a line terminator. If a
/// Codex TUI never emits a newline we don't want to grow unbounded.
const MAX_PARTIAL_LINE: usize = 16 * 1024;

fn socket_dir() -> PathBuf {
    std::env::temp_dir().join("sessionsd")
}

fn wrapper_socket_path(wrapper_id: &str) -> PathBuf {
    socket_dir().join(format!("cc-{wrapper_id}.sock"))
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Status {
    Running,
    NeedsApproval,
    Done,
    Idle,
    Exited,
    Unknown,
}

#[derive(Clone, Debug, Serialize)]
struct Message {
    role: String,
    kind: String, // text | tool_use | tool_result
    text: String,
    timestamp: Option<String>,
}

/// Structured description of whatever Claude Code is currently blocking on.
/// `Permission` and `PlanApproval` come from the Notification hook payload —
/// three fixed choices, injectable as `1\r`/`2\r`/`3\r`. `Question` comes from
/// transcript tailing (AskUserQuestion tool_use blocks) and carries a dynamic
/// option list with optional multi-select + free-text fallback. `Raw` is the
/// escape hatch for elicitation dialogs / unknown notification types — HUD
/// shows the message but can't auto-respond.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum PendingPrompt {
    Permission { message: String },
    PlanApproval { message: String },
    Question {
        tool_use_id: String,
        questions: Vec<AskQuestion>,
    },
    Raw { message: String },
}

#[derive(Clone, Debug, Serialize)]
struct AskQuestion {
    question: String,
    header: String,
    options: Vec<AskOption>,
    multi_select: bool,
}

#[derive(Clone, Debug, Serialize)]
struct AskOption {
    label: String,
    description: String,
}

/// Snapshot from the most recent Claude Code statusline invocation. Captured
/// by piping the statusline stdin JSON into `/hook/statusline`, which is the
/// only surface Anthropic exposes quota percentages on. Fields are all
/// optional because real payloads sometimes omit blocks (e.g. no rate_limits
/// block for unauthenticated or fresh sessions).
#[derive(Clone, Debug, Serialize)]
struct SessionStats {
    model_display: Option<String>,
    ctx_pct: Option<f32>,
    five_hr_pct: Option<f32>,
    seven_day_pct: Option<f32>,
    updated_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize)]
struct Session {
    id: String,
    name: String,
    status: Status,
    cwd: Option<String>,
    transcript_path: Option<PathBuf>,
    started_at: DateTime<Utc>,
    last_event_at: DateTime<Utc>,
    #[serde(skip)]
    bytes_read: u64,
    messages: Vec<Message>,
    /// Set when this session was started inside a `cc` PTY wrapper.
    wrapper_id: Option<String>,
    /// Controlling tty path of the host terminal (e.g. "/dev/ttys003"), copied
    /// from the bound wrapper so the HUD can focus the right terminal window.
    tty: Option<String>,
    /// $TERM_PROGRAM snapshot ("Apple_Terminal", "iTerm.app", …) for routing
    /// the "Open in Terminal" AppleScript to the right app.
    term_program: Option<String>,
    /// Unfinished tail of the last `/output` chunk, waiting for a newline.
    /// Only populated for Codex sessions (`cx`); Claude uses transcript tail.
    #[serde(skip)]
    output_partial: String,
    /// Whatever interactive prompt claude is currently blocked on. Cleared
    /// on SessionStart/UserPromptSubmit/Stop and on matching tool_result.
    pending_prompt: Option<PendingPrompt>,
    /// Latest statusline snapshot — model name + context/5h/7d usage.
    stats: Option<SessionStats>,
    /// What tool / subagent / compaction is currently running, if any.
    /// Set by PreToolUse/SubagentStart/PreCompact, cleared by the matching
    /// Post*. Also cleared by UserPromptSubmit/Stop as a belt-and-suspenders.
    current_activity: Option<Activity>,
}

/// Mirrors the Swift `Activity` enum. JSON tag is "kind" so the shape is
/// stable even when we add new variants.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum Activity {
    Tool { name: String, since: DateTime<Utc> },
    Subagent {
        #[serde(skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        since: DateTime<Utc>,
    },
    Compacting { since: DateTime<Utc> },
}

#[derive(Clone, Debug, Serialize)]
struct Wrapper {
    id: String,
    name: String,
    cwd: String,
    pid: u32,
    /// Bound when the SessionStart hook arrives carrying our wrapper_id.
    session_id: Option<String>,
    /// Unix domain socket `cc` binds to receive HUD-injected input.
    socket_path: String,
    tty: Option<String>,
    term_program: Option<String>,
    registered_at: DateTime<Utc>,
}

impl Session {
    fn new(id: String) -> Self {
        let now = Utc::now();
        let short = id.chars().take(8).collect::<String>();
        Self {
            id,
            name: short,
            status: Status::Unknown,
            cwd: None,
            transcript_path: None,
            started_at: now,
            last_event_at: now,
            bytes_read: 0,
            messages: Vec::new(),
            wrapper_id: None,
            tty: None,
            term_program: None,
            output_partial: String::new(),
            pending_prompt: None,
            stats: None,
            current_activity: None,
        }
    }
}

type Registry = Arc<RwLock<HashMap<String, Session>>>;
type WrapperRegistry = Arc<RwLock<HashMap<String, Wrapper>>>;

/// Broadcast event pushed to all `/events` SSE subscribers when the session
/// registry mutates. HUD clients react by refetching the affected slice.
/// We intentionally do NOT ship full session bodies over the wire here — the
/// snapshot routes (`/sessions`, `/sessions/:id`) remain the source of truth,
/// and SSE just carries cache-invalidation hints.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum SseEvent {
    /// The session list changed (add / remove / status transition). Clients
    /// should refetch `GET /sessions`.
    SessionsChanged,
    /// Detail of one session changed (messages appended, pending_prompt flip,
    /// stats update). Clients should refetch `GET /sessions/<id>` if they're
    /// displaying that session.
    SessionUpdated { id: String },
}

#[derive(Clone)]
struct AppState {
    registry: Registry,
    wrappers: WrapperRegistry,
    tx: broadcast::Sender<SseEvent>,
}

impl AppState {
    fn notify_list(&self) {
        let _ = self.tx.send(SseEvent::SessionsChanged);
    }
    fn notify_one(&self, id: &str) {
        let _ = self.tx.send(SseEvent::SessionUpdated { id: id.to_string() });
    }
}

#[derive(Deserialize, Debug)]
struct HookPayload {
    session_id: String,
    transcript_path: Option<PathBuf>,
    cwd: Option<String>,
    #[allow(dead_code)]
    #[serde(default)]
    permission_mode: Option<String>,
    #[allow(dead_code)]
    #[serde(default)]
    hook_event_name: Option<String>,
    /// Notification hook: human-readable message ("Claude needs your
    /// permission to use Bash" / "Claude is waiting for your input" / ...).
    #[serde(default)]
    message: Option<String>,
    /// Notification hook: machine-readable kind — `permission_prompt`,
    /// `idle_prompt`, or something we haven't seen yet.
    #[serde(default)]
    notification_type: Option<String>,
    /// PreToolUse / PostToolUse: name of the tool about to run / that just ran
    /// (e.g. "Bash", "Edit", "Agent").
    #[serde(default)]
    tool_name: Option<String>,
    /// SubagentStart / SubagentStop: the subagent kind (e.g. "Explore",
    /// "general-purpose"). Optional because some Agent invocations omit it.
    #[serde(default)]
    subagent_type: Option<String>,
}

/// Claude Code statusline stdin JSON — only the fields we care about. Everything
/// is optional because Anthropic sometimes omits blocks on fresh / unauthenticated
/// sessions and we don't want serde to reject the whole payload for a missing
/// field.
#[derive(Deserialize, Debug)]
struct StatuslinePayload {
    session_id: String,
    #[serde(default)]
    model: Option<StatuslineModel>,
    #[serde(default)]
    context_window: Option<PctBlock>,
    #[serde(default)]
    rate_limits: Option<StatuslineRateLimits>,
}

#[derive(Deserialize, Debug, Default)]
struct StatuslineModel {
    #[serde(default)]
    display_name: Option<String>,
}

#[derive(Deserialize, Debug, Default)]
struct PctBlock {
    #[serde(default)]
    used_percentage: Option<f32>,
}

#[derive(Deserialize, Debug, Default)]
struct StatuslineRateLimits {
    #[serde(default)]
    five_hour: Option<PctBlock>,
    #[serde(default)]
    seven_day: Option<PctBlock>,
}

async fn handle_hook(
    Path(event): Path<String>,
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<HookPayload>,
) -> impl IntoResponse {
    let wrapper_id = headers
        .get("x-cc-wrapper-id")
        .and_then(|v| v.to_str().ok())
        .map(String::from);

    tracing::info!(
        event = %event,
        session_id = %payload.session_id,
        wrapper_id = ?wrapper_id,
        "hook"
    );

    // SessionEnd: Claude Code exited gracefully. Short-circuit before the
    // `or_insert_with` below would otherwise resurrect the entry we're
    // cleaning up.
    if event == "SessionEnd" {
        drop_session(&state, &payload.session_id);
        tracing::info!(session_id = %payload.session_id, "session ended");
        state.notify_list();
        return StatusCode::OK;
    }

    // Look up wrapper name (if any) BEFORE taking the session write lock so
    // we don't hold two locks at once.
    let wrapper_info = wrapper_id.as_ref().and_then(|wid| {
        state
            .wrappers
            .read()
            .get(wid)
            .map(|w| (w.name.clone(), w.tty.clone(), w.term_program.clone()))
    });
    let wrapper_name = wrapper_info.as_ref().map(|(n, _, _)| n.clone());

    let session_id = payload.session_id.clone();
    let needs_new_tailer;
    // Tool-use hooks fire many times per second. We still broadcast the
    // list-level `SessionsChanged` (last_event_at moved, sort order might
    // care), but skip the per-session `SessionUpdated` detail ping unless
    // `current_activity` actually transitioned. Prevents the HUD ChatView
    // from refetching on every no-op PreToolUse/PostToolUse.
    let mut suppress_detail_notify = false;

    {
        let mut reg = state.registry.write();
        let session = reg
            .entry(session_id.clone())
            .or_insert_with(|| Session::new(session_id.clone()));

        session.last_event_at = Utc::now();

        if let Some(ref cwd) = payload.cwd {
            session.cwd = Some(cwd.clone());
            // Promote name from short id to cwd basename on first sight
            if session.name.len() <= 8 && session.name == &session.id[..session.name.len()] {
                if let Some(base) = std::path::Path::new(cwd).file_name() {
                    session.name = base.to_string_lossy().to_string();
                }
            }
        }

        // Wrapper name always wins over auto-derived names.
        if let Some(ref n) = wrapper_name {
            session.name = n.clone();
        }
        if let Some(ref wid) = wrapper_id {
            session.wrapper_id = Some(wid.clone());
        }
        if let Some((_, ref tty, ref tp)) = wrapper_info {
            if tty.is_some() {
                session.tty = tty.clone();
            }
            if tp.is_some() {
                session.term_program = tp.clone();
            }
        }

        let prev_tp = session.transcript_path.clone();
        if let Some(ref tp) = payload.transcript_path {
            session.transcript_path = Some(tp.clone());
        }
        needs_new_tailer = payload.transcript_path.is_some()
            && prev_tp.as_ref() != payload.transcript_path.as_ref();

        match event.as_str() {
            "SessionStart" | "UserPromptSubmit" => {
                session.status = Status::Running;
                // Fresh user activity — any prior blocking prompt is moot.
                session.pending_prompt = None;
                // A new turn starts clean — don't leak stale "Bash" chip if
                // PostToolUse went missing in the previous turn.
                session.current_activity = None;
            }
            "Notification" => {
                let msg = payload.message.clone().unwrap_or_default();
                match payload.notification_type.as_deref() {
                    Some("permission_prompt") => {
                        session.status = Status::NeedsApproval;
                        // "needs your approval for the plan" is a 3-choice
                        // auto-mode picker, not a tool permission — split it
                        // out so the HUD can label + route correctly.
                        session.pending_prompt = Some(if msg.contains("approval for the plan") {
                            PendingPrompt::PlanApproval { message: msg }
                        } else {
                            PendingPrompt::Permission { message: msg }
                        });
                    }
                    Some("idle_prompt") => {
                        // Idle is a passive hint, not a blocking action. Drop
                        // to Idle status but keep any AskUserQuestion etc.
                        // that might still be live from the transcript side.
                        session.status = Status::Idle;
                    }
                    _ => {
                        // Elicitation dialog / unknown — surface raw text
                        // but don't claim we know how to respond.
                        session.pending_prompt = Some(PendingPrompt::Raw { message: msg });
                    }
                }
            }
            "Stop" => {
                session.status = Status::Done;
                session.pending_prompt = None;
                session.current_activity = None;
            }
            "PreToolUse" => {
                let name = payload
                    .tool_name
                    .clone()
                    .unwrap_or_else(|| "tool".to_string());
                let same = matches!(
                    &session.current_activity,
                    Some(Activity::Tool { name: cn, .. }) if cn == &name
                );
                if !same {
                    session.current_activity = Some(Activity::Tool {
                        name,
                        since: Utc::now(),
                    });
                } else {
                    suppress_detail_notify = true;
                }
            }
            "PostToolUse" => {
                // Only clear when the finishing tool_name matches the tool we
                // currently have recorded. Missing tool_name is treated as a
                // no-op — without it we can't tell whether this Post belongs
                // to the Tool currently in `current_activity` or some other
                // concurrent call.
                let matches_current = matches!(
                    (&session.current_activity, payload.tool_name.as_deref()),
                    (Some(Activity::Tool { name: cn, .. }), Some(finishing)) if cn == finishing
                );
                if matches_current {
                    session.current_activity = None;
                } else {
                    suppress_detail_notify = true;
                }
            }
            "SubagentStart" => {
                let name = payload.subagent_type.clone();
                let same = matches!(
                    &session.current_activity,
                    Some(Activity::Subagent { name: cn, .. }) if cn == &name
                );
                if !same {
                    session.current_activity = Some(Activity::Subagent {
                        name,
                        since: Utc::now(),
                    });
                } else {
                    suppress_detail_notify = true;
                }
            }
            "SubagentStop" => {
                if matches!(session.current_activity, Some(Activity::Subagent { .. })) {
                    session.current_activity = None;
                } else {
                    suppress_detail_notify = true;
                }
            }
            "PreCompact" => {
                if !matches!(session.current_activity, Some(Activity::Compacting { .. })) {
                    session.current_activity = Some(Activity::Compacting { since: Utc::now() });
                } else {
                    suppress_detail_notify = true;
                }
            }
            "PostCompact" => {
                if matches!(session.current_activity, Some(Activity::Compacting { .. })) {
                    session.current_activity = None;
                } else {
                    suppress_detail_notify = true;
                }
            }
            _ => {}
        }
    }

    // Reverse-bind: tell the wrapper which session_id it ended up running.
    if let Some(wid) = wrapper_id {
        if let Some(w) = state.wrappers.write().get_mut(&wid) {
            w.session_id = Some(session_id.clone());
        }
    }

    if needs_new_tailer {
        let reg = state.registry.clone();
        let tx_clone = state.tx.clone();
        let sid = session_id.clone();
        tokio::spawn(async move {
            tail_session(reg, tx_clone, sid).await;
        });
    }

    // A hook event always changes list-level state (last_event_at drives
    // sort). Detail ping is suppressed when an activity hook was a no-op —
    // see `suppress_detail_notify` above.
    state.notify_list();
    if !suppress_detail_notify {
        state.notify_one(&session_id);
    }

    StatusCode::OK
}

/// Receive the Claude Code statusline stdin JSON (tee'd from the user's
/// statusline-command.sh) and stash the extracted percentages on the matching
/// session. Creates a stub Session if we haven't seen SessionStart yet —
/// statusline can fire before hook wiring is complete on the very first turn.
async fn handle_statusline(
    State(state): State<AppState>,
    Json(p): Json<StatuslinePayload>,
) -> StatusCode {
    let stats = SessionStats {
        model_display: p.model.and_then(|m| m.display_name),
        ctx_pct: p.context_window.and_then(|c| c.used_percentage),
        five_hr_pct: p
            .rate_limits
            .as_ref()
            .and_then(|r| r.five_hour.as_ref().and_then(|b| b.used_percentage)),
        seven_day_pct: p
            .rate_limits
            .as_ref()
            .and_then(|r| r.seven_day.as_ref().and_then(|b| b.used_percentage)),
        updated_at: Utc::now(),
    };
    let sid_for_event = p.session_id.clone();
    let was_new;
    {
        let mut reg = state.registry.write();
        if let Some(s) = reg.get_mut(&p.session_id) {
            s.stats = Some(stats);
            s.last_event_at = Utc::now();
            was_new = false;
        } else {
            let mut session = Session::new(p.session_id.clone());
            session.stats = Some(stats);
            reg.insert(p.session_id, session);
            was_new = true;
        }
    }
    if was_new {
        state.notify_list();
    }
    state.notify_one(&sid_for_event);
    StatusCode::OK
}

#[derive(Deserialize, Debug)]
struct RegisterRequest {
    name: String,
    cwd: String,
    pid: u32,
    #[serde(default)]
    tty: Option<String>,
    #[serde(default)]
    term_program: Option<String>,
}

#[derive(Serialize)]
struct RegisterResponse {
    wrapper_id: String,
    socket_path: String,
}

async fn register_wrapper(
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> Json<RegisterResponse> {
    let id = uuid::Uuid::new_v4().to_string();
    let sock = wrapper_socket_path(&id).to_string_lossy().to_string();
    tracing::info!(wrapper_id = %id, name = %req.name, pid = req.pid, socket = %sock, "wrapper registered");
    state.wrappers.write().insert(
        id.clone(),
        Wrapper {
            id: id.clone(),
            name: req.name,
            cwd: req.cwd,
            pid: req.pid,
            session_id: None,
            socket_path: sock.clone(),
            tty: req.tty,
            term_program: req.term_program,
            registered_at: Utc::now(),
        },
    );
    Json(RegisterResponse {
        wrapper_id: id,
        socket_path: sock,
    })
}

async fn unregister_wrapper(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> StatusCode {
    let removed = state.wrappers.write().remove(&id);
    if let Some(ref w) = removed {
        let _ = std::fs::remove_file(&w.socket_path);
    }
    tracing::info!(wrapper_id = %id, found = removed.is_some(), "wrapper unregistered");
    StatusCode::OK
}

async fn list_wrappers(State(state): State<AppState>) -> Json<Vec<Wrapper>> {
    Json(state.wrappers.read().values().cloned().collect())
}

/// Remove a session from the registry and (if bound) its wrapper + unix
/// socket file. Does NOT notify — callers who want HUD updates call
/// `state.notify_list()` themselves. Returns true if a session was removed.
fn drop_session(state: &AppState, session_id: &str) -> bool {
    let Some(removed) = state.registry.write().remove(session_id) else {
        return false;
    };
    if let Some(wid) = removed.wrapper_id {
        if let Some(w) = state.wrappers.write().remove(&wid) {
            let _ = std::fs::remove_file(&w.socket_path);
        }
    }
    true
}

/// HUD "Forget" action — drops a session without killing anything.
async fn forget_session(
    Path(session_id): Path<String>,
    State(state): State<AppState>,
) -> StatusCode {
    drop_session(&state, &session_id);
    tracing::info!(session_id = %session_id, "session forgotten");
    state.notify_list();
    StatusCode::NO_CONTENT
}

/// SIGTERM the wrapper process (fallback SIGKILL after 3s). Only works for
/// wrapper-backed sessions — returns 404 otherwise so the HUD can fall back
/// to Forget.
async fn terminate_wrapper(
    Path(session_id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, (StatusCode, String)> {
    let wrapper_id = {
        let reg = state.registry.read();
        reg.get(&session_id)
            .and_then(|s| s.wrapper_id.clone())
            .ok_or((StatusCode::NOT_FOUND, "session has no wrapper".into()))?
    };
    let pid = {
        let wrappers = state.wrappers.read();
        wrappers
            .get(&wrapper_id)
            .map(|w| w.pid)
            .ok_or((StatusCode::NOT_FOUND, "wrapper gone".into()))?
    };
    // Defence in depth: refuse obviously-wrong pids. kill(0|1|self) would be
    // catastrophic if state ever got corrupted.
    if pid <= 1 || pid == std::process::id() {
        return Err((StatusCode::BAD_REQUEST, format!("refusing to kill pid {pid}")));
    }
    let pid_i = pid as i32;
    unsafe {
        if libc::kill(pid_i, libc::SIGTERM) != 0 {
            let e = std::io::Error::last_os_error();
            // ESRCH = already gone; treat as success and let prune clean up.
            if e.raw_os_error() != Some(libc::ESRCH) {
                return Err((StatusCode::BAD_GATEWAY, format!("SIGTERM: {e}")));
            }
        }
    }
    tracing::info!(wrapper_id = %wrapper_id, pid, "SIGTERM sent");
    // Escalate to SIGKILL if the wrapper hasn't exited within 3s. The prune
    // loop handles cleanup either way — this just makes "Terminate" feel
    // decisive for hung wrappers.
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        unsafe {
            if libc::kill(pid_i, 0) == 0 {
                tracing::warn!(pid, "wrapper still alive after SIGTERM — SIGKILL");
                let _ = libc::kill(pid_i, libc::SIGKILL);
            }
        }
    });
    Ok(StatusCode::ACCEPTED)
}

#[derive(Deserialize)]
struct InjectRequest {
    text: String,
}

/// Connect to a wrapper's unix socket and write `text` into it. The wrapper's
/// socket listener forwards those bytes into its PTY master, which lands in
/// the child process's stdin.
fn write_to_wrapper_socket(socket_path: String, text: String) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::net::UnixStream;
    let mut s = UnixStream::connect(&socket_path)?;
    s.write_all(text.as_bytes())?;
    s.flush()
}

async fn inject_by_session(
    Path(session_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<InjectRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let wrapper_id = {
        let reg = state.registry.read();
        reg.get(&session_id)
            .and_then(|s| s.wrapper_id.clone())
            .ok_or((StatusCode::NOT_FOUND, "session has no wrapper".into()))?
    };
    let socket_path = {
        let wrappers = state.wrappers.read();
        wrappers
            .get(&wrapper_id)
            .map(|w| w.socket_path.clone())
            .ok_or((StatusCode::NOT_FOUND, "wrapper gone".into()))?
    };
    tokio::task::spawn_blocking(move || write_to_wrapper_socket(socket_path, req.text))
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("join: {e}")))?
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("inject: {e}")))?;
    Ok(StatusCode::OK)
}

/// Strip common ANSI escape sequences so Codex TUI output becomes readable
/// text in the HUD. We handle CSI (ESC `[` … final byte in 0x40..=0x7E),
/// OSC (ESC `]` … BEL or ESC \\), and single-char ESC sequences. Anything
/// unrecognized is dropped. Kept intentionally dependency-free — this is
/// best-effort, not a spec-compliant parser.
fn strip_ansi(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == 0x1b {
            // ESC
            if i + 1 >= bytes.len() {
                break;
            }
            match bytes[i + 1] {
                b'[' => {
                    // CSI: params then a final byte in 0x40..=0x7E
                    i += 2;
                    while i < bytes.len() {
                        let c = bytes[i];
                        i += 1;
                        if (0x40..=0x7e).contains(&c) {
                            break;
                        }
                    }
                }
                b']' => {
                    // OSC: terminated by BEL (0x07) or ST (ESC \)
                    i += 2;
                    while i < bytes.len() {
                        if bytes[i] == 0x07 {
                            i += 1;
                            break;
                        }
                        if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] == b'\\' {
                            i += 2;
                            break;
                        }
                        i += 1;
                    }
                }
                _ => {
                    // single-char escape (e.g. ESC 7 save cursor)
                    i += 2;
                }
            }
        } else if b == b'\r' {
            // CR without LF is usually cursor-return in a TUI — drop it so
            // repeated progress redraws don't clutter the transcript. If a
            // CRLF appears, let the LF survive.
            i += 1;
        } else if b == 0x08 {
            // Backspace — chew the previous char if we can.
            out.pop();
            i += 1;
        } else {
            out.push(b as char);
            i += 1;
        }
    }
    out
}

async fn append_output(
    Path(session_id): Path<String>,
    State(state): State<AppState>,
    body: Bytes,
) -> StatusCode {
    let text = match std::str::from_utf8(&body) {
        Ok(s) => s.to_string(),
        Err(_) => String::from_utf8_lossy(&body).into_owned(),
    };
    let cleaned = strip_ansi(&text);
    if cleaned.is_empty() {
        return StatusCode::OK;
    }

    let mut appended_any = false;
    {
        let mut reg = state.registry.write();
        let Some(session) = reg.get_mut(&session_id) else {
            return StatusCode::NOT_FOUND;
        };

        session.last_event_at = Utc::now();
        session.output_partial.push_str(&cleaned);

    // Split on newline; last element (if partial) stays buffered.
    let mut lines: Vec<String> = session
        .output_partial
        .split('\n')
        .map(|s| s.trim_end().to_string())
        .collect();
    let tail = lines.pop().unwrap_or_default();
    session.output_partial = tail;
    if session.output_partial.len() > MAX_PARTIAL_LINE {
        // force-flush an over-long line so memory stays bounded
        let forced = std::mem::take(&mut session.output_partial);
        lines.push(forced);
    }

        for line in lines {
            if line.is_empty() {
                continue;
            }
            session.messages.push(Message {
                role: "assistant".into(),
                kind: "text".into(),
                text: line,
                timestamp: Some(Utc::now().to_rfc3339()),
            });
            appended_any = true;
        }
        if session.messages.len() > MAX_MESSAGES_PER_SESSION {
            let drop = session.messages.len() - MAX_MESSAGES_PER_SESSION;
            session.messages.drain(0..drop);
        }
    }

    if appended_any {
        state.notify_one(&session_id);
    }

    StatusCode::OK
}

/// Debug-only injection: bypass session lookup and target a wrapper directly.
/// Useful for E2E tests where the PTY child (e.g. `bash` stub) doesn't emit
/// Claude Code hooks, so no session_id is ever bound.
async fn inject_by_wrapper(
    Path(wrapper_id): Path<String>,
    State(state): State<AppState>,
    Json(req): Json<InjectRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let socket_path = {
        let wrappers = state.wrappers.read();
        wrappers
            .get(&wrapper_id)
            .map(|w| w.socket_path.clone())
            .ok_or((StatusCode::NOT_FOUND, "wrapper not found".into()))?
    };
    tokio::task::spawn_blocking(move || write_to_wrapper_socket(socket_path, req.text))
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("join: {e}")))?
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("inject: {e}")))?;
    Ok(StatusCode::OK)
}

/// Periodically check that each registered wrapper's PID is still alive.
/// `cc` should call DELETE /wrappers/:id on clean exit, but if the user
/// closes their terminal window the shell sends SIGHUP and cc gets killed
/// before cleanup runs. This loop catches that case (and any other crash)
/// by polling kill(pid, 0).
async fn prune_dead_wrappers(state: AppState) {
    loop {
        tokio::time::sleep(WRAPPER_PRUNE_INTERVAL).await;

        // Snapshot dead wrappers under a read lock so we don't hold the
        // write lock during the syscall sweep.
        let dead: Vec<(String, Option<String>, String)> = {
            let wrappers = state.wrappers.read();
            wrappers
                .iter()
                .filter_map(|(id, w)| {
                    let alive = unsafe { libc::kill(w.pid as i32, 0) == 0 };
                    if alive {
                        None
                    } else {
                        Some((id.clone(), w.session_id.clone(), w.socket_path.clone()))
                    }
                })
                .collect()
        };

        if dead.is_empty() {
            continue;
        }

        {
            let mut wrappers = state.wrappers.write();
            for (wid, _, sock) in &dead {
                wrappers.remove(wid);
                let _ = std::fs::remove_file(sock);
                tracing::info!(wrapper_id = %wid, "pruned dead wrapper");
            }
        }

        // Mark each orphaned session as exited so the HUD can show 🔴.
        let mut touched: Vec<String> = Vec::new();
        {
            let mut reg = state.registry.write();
            for (_, sid, _) in &dead {
                if let Some(sid) = sid {
                    if let Some(s) = reg.get_mut(sid) {
                        s.status = Status::Exited;
                        s.last_event_at = Utc::now();
                        touched.push(sid.clone());
                    }
                }
            }
        }
        if !touched.is_empty() {
            state.notify_list();
            for sid in &touched {
                state.notify_one(sid);
            }
        }
    }
}

/// Safety net for native (hook-only) sessions the daemon will otherwise
/// remember forever: a user who SIGKILLs `claude`, force-quits Terminal, or
/// whose machine sleeps mid-session never fires SessionEnd, so the entry
/// lingers in the HUD indefinitely.
///
/// Every NATIVE_SWEEP_INTERVAL we walk the registry and drop entries that:
///   - have no wrapper (wrapper-backed sessions have their own prune loop),
///   - have no live pending_prompt (the user may still want to respond),
///   - are in a terminal-ish status (Done / Idle / Exited — never Running
///     or NeedsApproval),
///   - have been quiet for longer than the configured cutoff.
async fn sweep_stale_native_sessions(state: AppState) {
    let cutoff_hours = std::env::var("SESSIONSD_NATIVE_STALE_HOURS")
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .filter(|v| v.is_finite() && *v >= 0.0)
        .unwrap_or(DEFAULT_NATIVE_STALE_HOURS);
    let cutoff_secs = (cutoff_hours * 3600.0) as i64;
    let cutoff = chrono::Duration::seconds(cutoff_secs);
    tracing::info!(
        cutoff_hours,
        interval_secs = NATIVE_SWEEP_INTERVAL.as_secs(),
        "native stale sweeper armed"
    );

    loop {
        tokio::time::sleep(NATIVE_SWEEP_INTERVAL).await;

        let now = Utc::now();
        let victims: Vec<String> = {
            let reg = state.registry.read();
            reg.iter()
                .filter_map(|(id, s)| {
                    if s.wrapper_id.is_some() {
                        return None;
                    }
                    if s.pending_prompt.is_some() {
                        return None;
                    }
                    match s.status {
                        Status::Done | Status::Idle | Status::Exited => {}
                        _ => return None,
                    }
                    if now.signed_duration_since(s.last_event_at) < cutoff {
                        return None;
                    }
                    Some(id.clone())
                })
                .collect()
        };

        if victims.is_empty() {
            continue;
        }

        {
            let mut reg = state.registry.write();
            for id in &victims {
                reg.remove(id);
                tracing::info!(session_id = %id, "native session swept (stale)");
            }
        }
        state.notify_list();
    }
}

async fn tail_session(
    registry: Registry,
    tx: broadcast::Sender<SseEvent>,
    session_id: String,
) {
    let path = {
        let reg = registry.read();
        reg.get(&session_id).and_then(|s| s.transcript_path.clone())
    };
    let Some(path) = path else { return };

    tracing::info!(session_id = %session_id, ?path, "tailer started");

    loop {
        match read_new_lines(&registry, &session_id, &path).await {
            Ok(true) => {
                let _ = tx.send(SseEvent::SessionUpdated { id: session_id.clone() });
            }
            Ok(false) => {}
            Err(e) => {
                tracing::warn!(session_id = %session_id, err = %e, "tail read error");
            }
        }

        let still_present = registry.read().contains_key(&session_id);
        if !still_present {
            tracing::info!(session_id = %session_id, "tailer stopping (session removed)");
            break;
        }

        tokio::time::sleep(TAIL_INTERVAL).await;
    }
}

async fn read_new_lines(
    registry: &Registry,
    session_id: &str,
    path: &std::path::Path,
) -> Result<bool> {
    let bytes_read = registry
        .read()
        .get(session_id)
        .map(|s| s.bytes_read)
        .unwrap_or(0);

    let metadata = match tokio::fs::metadata(path).await {
        Ok(m) => m,
        Err(_) => return Ok(false), // file not yet created
    };

    if metadata.len() <= bytes_read {
        return Ok(false);
    }

    let mut file = File::open(path).await?;
    file.seek(SeekFrom::Start(bytes_read)).await?;
    let mut reader = BufReader::new(file);

    let mut new_messages = Vec::new();
    let mut new_events: Vec<PromptEvent> = Vec::new();
    let mut new_pos = bytes_read;
    let mut line = String::new();

    loop {
        line.clear();
        let n = reader.read_line(&mut line).await?;
        if n == 0 {
            break;
        }
        // Only consume complete lines, leave a partial trailing line for next pass
        if !line.ends_with('\n') {
            break;
        }
        new_pos += n as u64;
        let (msg, mut evs) = parse_jsonl_line(line.trim());
        if let Some(msg) = msg {
            new_messages.push(msg);
        }
        new_events.append(&mut evs);
    }

    let had_update = new_pos != bytes_read || !new_messages.is_empty() || !new_events.is_empty();
    if had_update {
        let mut reg = registry.write();
        if let Some(s) = reg.get_mut(session_id) {
            s.bytes_read = new_pos;
            s.messages.extend(new_messages);
            if s.messages.len() > MAX_MESSAGES_PER_SESSION {
                let drop = s.messages.len() - MAX_MESSAGES_PER_SESSION;
                s.messages.drain(0..drop);
            }
            // Apply AskUserQuestion prompt state from this batch: start
            // events set pending_prompt, a matching tool_result clears it.
            for ev in new_events {
                match ev {
                    PromptEvent::AskStart { tool_use_id, questions } => {
                        s.pending_prompt = Some(PendingPrompt::Question {
                            tool_use_id,
                            questions,
                        });
                    }
                    PromptEvent::ToolResult { tool_use_id } => {
                        if let Some(PendingPrompt::Question { tool_use_id: pending_id, .. }) =
                            &s.pending_prompt
                        {
                            if pending_id == &tool_use_id {
                                s.pending_prompt = None;
                            }
                        }
                    }
                }
            }
        }
    }

    Ok(had_update)
}

/// Events extracted from transcript tool blocks that affect `pending_prompt`.
/// Kept separate from `Message` so the tailer can apply them atomically
/// alongside message appends.
enum PromptEvent {
    AskStart {
        tool_use_id: String,
        questions: Vec<AskQuestion>,
    },
    ToolResult {
        tool_use_id: String,
    },
}

fn parse_jsonl_line(line: &str) -> (Option<Message>, Vec<PromptEvent>) {
    let empty: (Option<Message>, Vec<PromptEvent>) = (None, Vec::new());
    let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
        return empty;
    };
    let Some(top_type) = v.get("type").and_then(|t| t.as_str()) else {
        return empty;
    };
    if top_type != "user" && top_type != "assistant" {
        return empty;
    }
    let Some(msg) = v.get("message") else { return empty };
    let Some(role) = msg.get("role").and_then(|r| r.as_str()).map(String::from) else {
        return empty;
    };
    let timestamp = v
        .get("timestamp")
        .and_then(|t| t.as_str())
        .map(String::from);

    let Some(content) = msg.get("content") else { return empty };

    // content can be a plain string (user prompt) or an array of typed blocks
    if let Some(s) = content.as_str() {
        return (
            Some(Message {
                role,
                kind: "text".into(),
                text: s.to_string(),
                timestamp,
            }),
            Vec::new(),
        );
    }

    let Some(blocks) = content.as_array() else { return empty };
    let mut parts = Vec::new();
    let mut kind = "text";
    let mut events: Vec<PromptEvent> = Vec::new();
    for block in blocks {
        let bt = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
        match bt {
            "text" => {
                if let Some(s) = block.get("text").and_then(|t| t.as_str()) {
                    parts.push(s.to_string());
                }
            }
            "thinking" => {} // intentionally skipped — too noisy for HUD
            "tool_use" => {
                let name = block.get("name").and_then(|n| n.as_str()).unwrap_or("?");
                parts.push(format!("[tool: {name}]"));
                kind = "tool_use";
                // AskUserQuestion carries a structured question list we can
                // render natively in the HUD banner.
                if name == "AskUserQuestion" {
                    if let (Some(id), Some(questions)) = (
                        block.get("id").and_then(|i| i.as_str()),
                        block
                            .get("input")
                            .and_then(|inp| inp.get("questions"))
                            .and_then(|q| q.as_array()),
                    ) {
                        let parsed = questions
                            .iter()
                            .filter_map(parse_ask_question)
                            .collect::<Vec<_>>();
                        if !parsed.is_empty() {
                            events.push(PromptEvent::AskStart {
                                tool_use_id: id.to_string(),
                                questions: parsed,
                            });
                        }
                    }
                }
            }
            "tool_result" => {
                let preview = block
                    .get("content")
                    .and_then(|c| c.as_str())
                    .map(|s| s.chars().take(200).collect::<String>())
                    .unwrap_or_default();
                parts.push(format!("[tool result] {preview}"));
                kind = "tool_result";
                if let Some(id) = block.get("tool_use_id").and_then(|i| i.as_str()) {
                    events.push(PromptEvent::ToolResult {
                        tool_use_id: id.to_string(),
                    });
                }
            }
            _ => {}
        }
    }

    if parts.is_empty() {
        return (None, events);
    }

    (
        Some(Message {
            role,
            kind: kind.into(),
            text: parts.join("\n"),
            timestamp,
        }),
        events,
    )
}

fn parse_ask_question(v: &serde_json::Value) -> Option<AskQuestion> {
    let question = v.get("question")?.as_str()?.to_string();
    let header = v
        .get("header")
        .and_then(|h| h.as_str())
        .unwrap_or("")
        .to_string();
    let multi_select = v
        .get("multiSelect")
        .and_then(|m| m.as_bool())
        .unwrap_or(false);
    let options = v
        .get("options")
        .and_then(|o| o.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|opt| {
                    let label = opt.get("label")?.as_str()?.to_string();
                    let description = opt
                        .get("description")
                        .and_then(|d| d.as_str())
                        .unwrap_or("")
                        .to_string();
                    Some(AskOption { label, description })
                })
                .collect()
        })
        .unwrap_or_default();
    Some(AskQuestion {
        question,
        header,
        options,
        multi_select,
    })
}

#[derive(Serialize)]
struct SessionSummary {
    id: String,
    name: String,
    status: Status,
    cwd: Option<String>,
    last_event_at: DateTime<Utc>,
    started_at: DateTime<Utc>,
    message_count: usize,
    wrapper_id: Option<String>,
    pending_prompt: Option<PendingPrompt>,
    stats: Option<SessionStats>,
    current_activity: Option<Activity>,
}

async fn list_sessions(State(state): State<AppState>) -> Json<Vec<SessionSummary>> {
    let reg = state.registry.read();
    let mut sessions: Vec<SessionSummary> = reg
        .values()
        .map(|s| SessionSummary {
            id: s.id.clone(),
            name: s.name.clone(),
            status: s.status.clone(),
            cwd: s.cwd.clone(),
            last_event_at: s.last_event_at,
            started_at: s.started_at,
            message_count: s.messages.len(),
            wrapper_id: s.wrapper_id.clone(),
            pending_prompt: s.pending_prompt.clone(),
            stats: s.stats.clone(),
            current_activity: s.current_activity.clone(),
        })
        .collect();
    sessions.sort_by(|a, b| b.last_event_at.cmp(&a.last_event_at));
    Json(sessions)
}

async fn get_session(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<Session>, StatusCode> {
    state
        .registry
        .read()
        .get(&id)
        .cloned()
        .map(Json)
        .ok_or(StatusCode::NOT_FOUND)
}

async fn health() -> &'static str {
    "ok"
}

/// SSE endpoint: clients subscribe here to receive cache-invalidation events
/// as soon as they happen instead of polling `/sessions` on a timer. The
/// stream also emits a synthetic `hello` event immediately so clients know
/// the connection is live before any real event fires, plus a 15-second
/// heartbeat comment to keep NAT / HTTP proxies from reaping the socket.
async fn sse_events(
    State(state): State<AppState>,
) -> Sse<impl Stream<Item = Result<Event, axum::Error>>> {
    let rx = state.tx.subscribe();
    let hello = futures::stream::once(async {
        Ok(Event::default().event("hello").data("{}"))
    });
    let live = BroadcastStream::new(rx).filter_map(|res| match res {
        Ok(ev) => serde_json::to_string(&ev)
            .ok()
            .map(|json| Ok(Event::default().data(json))),
        // Lagged: client was too slow. Silently drop — the HUD will refresh
        // its snapshot on the next event or on reconnect.
        Err(_) => None,
    });
    Sse::new(hello.chain(live)).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "sessionsd=info".into()),
        )
        .init();

    // Ensure the unix socket directory exists with restrictive perms so only
    // our uid can read/write the per-wrapper sockets.
    {
        let dir = socket_dir();
        std::fs::create_dir_all(&dir)?;
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    }

    let (tx, _rx) = broadcast::channel::<SseEvent>(256);
    let state = AppState {
        registry: Arc::new(RwLock::new(HashMap::new())),
        wrappers: Arc::new(RwLock::new(HashMap::new())),
        tx,
    };

    // Background task: prune wrappers whose PID has gone away.
    tokio::spawn(prune_dead_wrappers(state.clone()));
    // Background task: sweep native (hook-only) sessions that missed
    // SessionEnd — safety net for SIGKILL / force-quit / sleep.
    tokio::spawn(sweep_stale_native_sessions(state.clone()));

    let app = Router::new()
        .route("/health", get(health))
        .route("/events", get(sse_events))
        .route("/sessions", get(list_sessions))
        .route("/sessions/:id", get(get_session).delete(forget_session))
        .route("/sessions/:id/input", post(inject_by_session))
        .route("/sessions/:id/output", post(append_output))
        .route("/sessions/:id/terminate", post(terminate_wrapper))
        .route("/hook/statusline", post(handle_statusline))
        .route("/hook/:event", post(handle_hook))
        .route("/register", post(register_wrapper))
        .route("/wrappers", get(list_wrappers))
        .route("/wrappers/:id", delete(unregister_wrapper))
        .route("/wrappers/:id/input", post(inject_by_wrapper))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(LISTEN_ADDR).await?;
    tracing::info!("sessionsd listening on http://{LISTEN_ADDR}");
    axum::serve(listener, app).await?;

    Ok(())
}
