use anyhow::Result;
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json},
    routing::{delete, get, post},
    Router,
};
use chrono::{DateTime, Utc};
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::fs::File;
use tokio::io::{AsyncBufReadExt, AsyncSeekExt, BufReader, SeekFrom};

const LISTEN_ADDR: &str = "127.0.0.1:39501";
const TAIL_INTERVAL: Duration = Duration::from_millis(500);
const MAX_MESSAGES_PER_SESSION: usize = 500;
const WRAPPER_PRUNE_INTERVAL: Duration = Duration::from_secs(5);

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
}

#[derive(Clone, Debug, Serialize)]
struct Wrapper {
    id: String,
    name: String,
    cwd: String,
    pid: u32,
    /// Bound when the SessionStart hook arrives carrying our wrapper_id.
    session_id: Option<String>,
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
        }
    }
}

type Registry = Arc<RwLock<HashMap<String, Session>>>;
type WrapperRegistry = Arc<RwLock<HashMap<String, Wrapper>>>;

#[derive(Clone)]
struct AppState {
    registry: Registry,
    wrappers: WrapperRegistry,
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

    // Look up wrapper name (if any) BEFORE taking the session write lock so
    // we don't hold two locks at once.
    let wrapper_name = wrapper_id
        .as_ref()
        .and_then(|wid| state.wrappers.read().get(wid).map(|w| w.name.clone()));

    let session_id = payload.session_id.clone();
    let needs_new_tailer;

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

        let prev_tp = session.transcript_path.clone();
        if let Some(ref tp) = payload.transcript_path {
            session.transcript_path = Some(tp.clone());
        }
        needs_new_tailer = payload.transcript_path.is_some()
            && prev_tp.as_ref() != payload.transcript_path.as_ref();

        match event.as_str() {
            "SessionStart" | "UserPromptSubmit" => session.status = Status::Running,
            "Notification" => session.status = Status::NeedsApproval,
            "Stop" => session.status = Status::Done,
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
        tokio::spawn(async move {
            tail_session(reg, session_id).await;
        });
    }

    StatusCode::OK
}

#[derive(Deserialize, Debug)]
struct RegisterRequest {
    name: String,
    cwd: String,
    pid: u32,
}

#[derive(Serialize)]
struct RegisterResponse {
    wrapper_id: String,
}

async fn register_wrapper(
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> Json<RegisterResponse> {
    let id = uuid::Uuid::new_v4().to_string();
    tracing::info!(wrapper_id = %id, name = %req.name, pid = req.pid, "wrapper registered");
    state.wrappers.write().insert(
        id.clone(),
        Wrapper {
            id: id.clone(),
            name: req.name,
            cwd: req.cwd,
            pid: req.pid,
            session_id: None,
            registered_at: Utc::now(),
        },
    );
    Json(RegisterResponse { wrapper_id: id })
}

async fn unregister_wrapper(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> StatusCode {
    let removed = state.wrappers.write().remove(&id);
    tracing::info!(wrapper_id = %id, found = removed.is_some(), "wrapper unregistered");
    StatusCode::OK
}

async fn list_wrappers(State(state): State<AppState>) -> Json<Vec<Wrapper>> {
    Json(state.wrappers.read().values().cloned().collect())
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
        let dead: Vec<(String, Option<String>)> = {
            let wrappers = state.wrappers.read();
            wrappers
                .iter()
                .filter_map(|(id, w)| {
                    let alive = unsafe { libc::kill(w.pid as i32, 0) == 0 };
                    if alive {
                        None
                    } else {
                        Some((id.clone(), w.session_id.clone()))
                    }
                })
                .collect()
        };

        if dead.is_empty() {
            continue;
        }

        {
            let mut wrappers = state.wrappers.write();
            for (wid, _) in &dead {
                wrappers.remove(wid);
                tracing::info!(wrapper_id = %wid, "pruned dead wrapper");
            }
        }

        // Mark each orphaned session as exited so the HUD can show 🔴.
        {
            let mut reg = state.registry.write();
            for (_, sid) in &dead {
                if let Some(sid) = sid {
                    if let Some(s) = reg.get_mut(sid) {
                        s.status = Status::Exited;
                        s.last_event_at = Utc::now();
                    }
                }
            }
        }
    }
}

async fn tail_session(registry: Registry, session_id: String) {
    let path = {
        let reg = registry.read();
        reg.get(&session_id).and_then(|s| s.transcript_path.clone())
    };
    let Some(path) = path else { return };

    tracing::info!(session_id = %session_id, ?path, "tailer started");

    loop {
        if let Err(e) = read_new_lines(&registry, &session_id, &path).await {
            tracing::warn!(session_id = %session_id, err = %e, "tail read error");
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
) -> Result<()> {
    let bytes_read = registry
        .read()
        .get(session_id)
        .map(|s| s.bytes_read)
        .unwrap_or(0);

    let metadata = match tokio::fs::metadata(path).await {
        Ok(m) => m,
        Err(_) => return Ok(()), // file not yet created
    };

    if metadata.len() <= bytes_read {
        return Ok(());
    }

    let mut file = File::open(path).await?;
    file.seek(SeekFrom::Start(bytes_read)).await?;
    let mut reader = BufReader::new(file);

    let mut new_messages = Vec::new();
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
        if let Some(msg) = parse_jsonl_line(line.trim()) {
            new_messages.push(msg);
        }
    }

    if new_pos != bytes_read || !new_messages.is_empty() {
        let mut reg = registry.write();
        if let Some(s) = reg.get_mut(session_id) {
            s.bytes_read = new_pos;
            s.messages.extend(new_messages);
            if s.messages.len() > MAX_MESSAGES_PER_SESSION {
                let drop = s.messages.len() - MAX_MESSAGES_PER_SESSION;
                s.messages.drain(0..drop);
            }
        }
    }

    Ok(())
}

fn parse_jsonl_line(line: &str) -> Option<Message> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    let top_type = v.get("type")?.as_str()?;
    if top_type != "user" && top_type != "assistant" {
        return None;
    }
    let msg = v.get("message")?;
    let role = msg.get("role")?.as_str()?.to_string();
    let timestamp = v
        .get("timestamp")
        .and_then(|t| t.as_str())
        .map(String::from);

    let content = msg.get("content")?;

    // content can be a plain string (user prompt) or an array of typed blocks
    if let Some(s) = content.as_str() {
        return Some(Message {
            role,
            kind: "text".into(),
            text: s.to_string(),
            timestamp,
        });
    }

    let blocks = content.as_array()?;
    let mut parts = Vec::new();
    let mut kind = "text";
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
            }
            "tool_result" => {
                let preview = block
                    .get("content")
                    .and_then(|c| c.as_str())
                    .map(|s| s.chars().take(200).collect::<String>())
                    .unwrap_or_default();
                parts.push(format!("[tool result] {preview}"));
                kind = "tool_result";
            }
            _ => {}
        }
    }

    if parts.is_empty() {
        return None;
    }

    Some(Message {
        role,
        kind: kind.into(),
        text: parts.join("\n"),
        timestamp,
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

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "sessionsd=info".into()),
        )
        .init();

    let state = AppState {
        registry: Arc::new(RwLock::new(HashMap::new())),
        wrappers: Arc::new(RwLock::new(HashMap::new())),
    };

    // Background task: prune wrappers whose PID has gone away.
    tokio::spawn(prune_dead_wrappers(state.clone()));

    let app = Router::new()
        .route("/health", get(health))
        .route("/sessions", get(list_sessions))
        .route("/sessions/:id", get(get_session))
        .route("/hook/:event", post(handle_hook))
        .route("/register", post(register_wrapper))
        .route("/wrappers", get(list_wrappers))
        .route("/wrappers/:id", delete(unregister_wrapper))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(LISTEN_ADDR).await?;
    tracing::info!("sessionsd listening on http://{LISTEN_ADDR}");
    axum::serve(listener, app).await?;

    Ok(())
}
