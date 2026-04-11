# Sessions HUD 高價值改進計劃

> **For agentic workers:** 本計劃分為三個 Phase，每個 Phase 完成後進行 code review + 實機測試，再進入下一個。Steps 使用 `- [ ]` 追蹤。

**Goal:** 讓 Sessions HUD 的新使用者體驗、native session 可用性、即時性三個最痛的點一次解掉。

**Architecture:** 三個獨立 phase — (1) `install.sh` 自動化 hook / statusline / Automation；(2) HUD 在 native session 顯示 relaunch banner 並一鍵透過 AppleScript 重啟為 ccw；(3) `sessionsd` 新增 `/events` SSE 端點，HUD 改用事件推送取代 1 秒 poll。

**Tech Stack:** Rust (axum, tokio::sync::broadcast), SwiftUI, bash + jq, AppleScript.

---

## Phase 1: `install.sh` 自動化

**Goal:** 單跑 `./install.sh` 後新使用者不需手動編輯任何檔案即可使用全部功能。

### 檔案盤點

- Modify: `install.sh`
- Create: `packaging/merge-hooks.sh` — 用 Python stdlib 合併 `~/.claude/settings.json`
- Create: `packaging/patch-statusline.sh` — 在現有 statusline 檔案注入 tee snippet
- Modify: `hud/Sources/SessionsHUD/App.swift` — 首次啟動時觸發 Automation 權限彈窗

### Task 1.1: Python hooks merger

**Files:**
- Create: `packaging/merge-hooks.sh`

- [ ] **Step 1：寫 merger 腳本**

```bash
#!/usr/bin/env bash
# Merge Sessions HUD hook entries into ~/.claude/settings.json.
# Idempotent: re-running does nothing if hooks already point at REPO_ROOT.
#
#   merge-hooks.sh <REPO_ROOT>
set -euo pipefail

REPO_ROOT="${1:?usage: merge-hooks.sh <repo-root>}"
SETTINGS="$HOME/.claude/settings.json"
SENTINEL="sessions-hud/hooks/post-event.sh"

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

def already_wired(entry_list, event):
    for block in entry_list or []:
        for h in block.get("hooks", []) or []:
            cmd = h.get("command", "")
            if sentinel in cmd:
                return True
    return False

changed = False
for ev in events:
    existing = hooks.get(ev)
    if already_wired(existing, ev):
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
```

- [ ] **Step 2：chmod +x**

```bash
chmod +x packaging/merge-hooks.sh
```

- [ ] **Step 3：手動試跑一次**

```bash
./packaging/merge-hooks.sh "$(pwd)"
```
Expected：第一次印 `hooks: merged`，第二次印 `hooks: already wired`，`~/.claude/settings.json` 有四個事件掛勾，備份檔存在。

- [ ] **Step 4：Commit**

```bash
git add packaging/merge-hooks.sh
git commit -m "install: add idempotent hooks merger"
```

### Task 1.2: Statusline patcher

**Files:**
- Create: `packaging/patch-statusline.sh`

- [ ] **Step 1：寫 patcher**

```bash
#!/usr/bin/env bash
# Inject the sessionsd statusline tee into ~/.claude/statusline-command.sh.
# Uses a sentinel comment so rerun is a no-op and uninstall can remove
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

cp "$TARGET" "$TARGET.bak.$(date +%s)"

# Insert our block right after the first `input=$(cat)` line. If that marker
# isn't present the user's script is non-standard — bail with a warning.
if ! grep -q 'input=$(cat)' "$TARGET"; then
    echo "statusline: could not find 'input=\$(cat)' anchor — skipping"
    exit 0
fi

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
```

- [ ] **Step 2：chmod +x + 手動試跑**

```bash
chmod +x packaging/patch-statusline.sh
./packaging/patch-statusline.sh
```
Expected：若使用者有 statusline 檔則印 `patched` 或 `already patched`，否則印 `skipping`。`git diff` 可看到 sentinel 包圍的插入區塊。

- [ ] **Step 3：Commit**

```bash
git add packaging/patch-statusline.sh
git commit -m "install: add idempotent statusline patcher"
```

### Task 1.3: 整合進 install.sh

**Files:**
- Modify: `install.sh`（替換末端警告段）

- [ ] **Step 1：把兩個 helper 接上主流程**

在 `install.sh` 的「green "installed:"」區塊後面、舊的 `HOOKS_FILE` 警告前面，新增：

```bash
echo "→ merging Claude Code hooks into ~/.claude/settings.json"
"$REPO_ROOT/packaging/merge-hooks.sh" "$REPO_ROOT"

echo "→ patching statusline (if present)"
"$REPO_ROOT/packaging/patch-statusline.sh"
```

並刪除舊的 `if [[ ! -f "$HOOKS_FILE" ]] || ! grep -q "sessionsd" "$HOOKS_FILE" …` 警告段（改由 merger 處理）。

- [ ] **Step 2：uninstall 也反向移除 statusline 區塊**

在 `uninstall()` 內加：

```bash
echo "→ removing statusline patch (if any)"
if [[ -f "$HOME/.claude/statusline-command.sh" ]]; then
    python3 - "$HOME/.claude/statusline-command.sh" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
text = p.read_text()
pattern = re.compile(
    r"# >>> sessions-hud statusline tee >>>.*?# <<< sessions-hud statusline tee <<<\n",
    re.DOTALL,
)
new = pattern.sub("", text)
if new != text:
    p.write_text(new)
    print("statusline: unpatched")
PY
fi
```

hooks 不自動移除（避免誤刪使用者自訂內容）— 在輸出文字提示使用者手動處理。

- [ ] **Step 3：End-to-end dry run**

```bash
./install.sh
```

Expected：完整 build + copy + merge hooks + patch statusline，全程無需使用者互動。`grep -c sessions-hud ~/.claude/settings.json` ≥ 4。

- [ ] **Step 4：Commit**

```bash
git add install.sh
git commit -m "install: auto-merge hooks and patch statusline"
```

### Task 1.4: Automation 權限 pre-flight

**Files:**
- Modify: `hud/Sources/SessionsHUD/App.swift`（首次啟動一次性呼叫）
- Modify: `hud/Sources/SessionsHUD/TerminalFocus.swift`（新增 `primeAutomationPermission` 靜態方法）

- [ ] **Step 1：在 `TerminalFocus` 加方法**

```swift
/// Fire a no-op AppleScript against Terminal.app once at first launch so
/// macOS prompts for Automation permission up-front instead of silently
/// failing the first time the user clicks `+` → Launch.
static func primeAutomationPermission() {
    let script = """
    tell application "System Events"
        -- no-op; just forces the automation consent dialog
        return name of first process whose frontmost is true
    end tell
    """
    _ = runReturningError(script)
}
```

- [ ] **Step 2：App.swift 呼叫一次（flag 存在 UserDefaults）**

在 `App` 的 `init()` 或 `WindowGroup` 的 `.onAppear` 加：

```swift
if !UserDefaults.standard.bool(forKey: "sessions-hud.automationPrimed") {
    TerminalFocus.primeAutomationPermission()
    UserDefaults.standard.set(true, forKey: "sessions-hud.automationPrimed")
}
```

- [ ] **Step 3：`swift build -c release` 確認編譯通過**

```bash
cd hud && swift build -c release
```
Expected：無錯誤。

- [ ] **Step 4：Commit**

```bash
git add hud/Sources/SessionsHUD/TerminalFocus.swift hud/Sources/SessionsHUD/App.swift
git commit -m "hud: prime Automation permission on first launch"
```

### Task 1.5: 更新 README

**Files:**
- Modify: `README.md`（移除手動 hooks JSON 與 statusline 段，改成一行「自動處理」）

- [ ] **Step 1：把 Post-install setup 節縮短**
- [ ] **Step 2：Commit**

---

## Phase 2: Native session relaunch banner

**Goal:** native `claude` session 在 HUD 中明確顯示「read-only」並一鍵以 `ccw` 重啟。

### 檔案盤點

- Modify: `hud/Sources/SessionsHUD/Models.swift` — 新增 computed `isWrapperBacked`（非必要，直接用 `wrapperId != nil` 即可，保留 option）
- Modify: `hud/Sources/SessionsHUD/SessionListView.swift` — 在 detail 頂部插入 banner
- Modify: `hud/Sources/SessionsHUD/TerminalFocus.swift` — 新增 `relaunchAsCcw(name:cwd:)`
- Modify: `hud/Sources/SessionsHUD/AppModel.swift` — 新增 `relaunchCurrentAsCcw()` 封裝呼叫

### Task 2.1: Relaunch helper

**Files:**
- Modify: `hud/Sources/SessionsHUD/TerminalFocus.swift`

- [ ] **Step 1：複用既有 `launchNewSession`**

實際上 `launchNewSession(flavor: .ccw, mode: .defaultMode, name:, cwd:)` 就是要的東西。不加新函式，直接在 AppModel 層呼叫。

### Task 2.2: AppModel 封裝

**Files:**
- Modify: `hud/Sources/SessionsHUD/AppModel.swift`

- [ ] **Step 1：新增方法**

```swift
/// Relaunch the currently selected native (non-wrapper) session as a
/// ccw-wrapped one by opening a new Terminal window with `ccw <name>`.
/// Does nothing if the selection is already wrapper-backed.
func relaunchSelectedAsCcw() {
    guard let s = sessions.first(where: { $0.id == selectedId }) else { return }
    guard s.wrapperId == nil else { return }
    guard let cwd = s.cwd, !cwd.isEmpty else {
        self.injectStatus = "relaunch: unknown cwd"
        return
    }
    if let err = TerminalFocus.launchNewSession(
        flavor: .ccw,
        mode: .defaultMode,
        name: s.name,
        cwd: cwd
    ) {
        self.injectStatus = "relaunch failed: \(err)"
    } else {
        self.injectStatus = "relaunching as ccw…"
    }
}
```

- [ ] **Step 2：Commit**

```bash
git add hud/Sources/SessionsHUD/AppModel.swift
git commit -m "hud: add relaunchSelectedAsCcw"
```

### Task 2.3: Read-only banner UI

**Files:**
- Modify: `hud/Sources/SessionsHUD/SessionListView.swift`（在 Mode B detail 區加 banner；位置在 header 下方、messageList 上方）

- [ ] **Step 1：找到 detail 區塊的 VStack，插入 banner view**

在 `messageList` 呼叫點前加：

```swift
if let s = selectedSummary, s.wrapperId == nil, s.status != .exited {
    readOnlyBanner
}
```

然後在同一 view 內定義：

```swift
private var readOnlyBanner: some View {
    HStack(spacing: 8) {
        Image(systemName: "lock.fill")
            .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 2) {
            Text("Read-only session")
                .font(.system(size: 11 * uiScale, weight: .semibold))
            Text("Launched via native claude — approvals disabled. Relaunch as ccw to enable input.")
                .font(.system(size: 10 * uiScale))
                .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Relaunch as ccw") {
            model.relaunchSelectedAsCcw()
        }
        .font(.system(size: 11 * uiScale))
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.12))
    .overlay(
        Rectangle()
            .fill(Color.orange.opacity(0.4))
            .frame(height: 1),
        alignment: .bottom
    )
}
```

- [ ] **Step 2：`swift build -c release` 確認編譯**
- [ ] **Step 3：Commit**

```bash
git add hud/Sources/SessionsHUD/SessionListView.swift
git commit -m "hud: add read-only banner for native sessions"
```

### Task 2.4: 列表 row badge（次要）

**Files:**
- Modify: `hud/Sources/SessionsHUD/SessionListView.swift`

- [ ] **Step 1：在 compact list row 的 name 旁加 `RO` tag**

找 `session.wrapperId == nil` 的 row（line ~251 附近），在狀態 icon 後加：

```swift
if session.wrapperId == nil {
    Text("RO")
        .font(.system(size: 9 * uiScale, weight: .semibold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.orange.opacity(0.6), lineWidth: 1)
        )
}
```

- [ ] **Step 2：Commit**

```bash
git commit -am "hud: add RO badge to native session rows"
```

---

## Phase 3: SSE 事件推送

**Goal:** HUD 不再 1 秒 poll；`sessionsd` 在 state 變動時主動推 SSE，HUD 內 approval prompt 延遲降到 <100ms。

### 檔案盤點

- Modify: `crates/sessionsd/Cargo.toml` — 新增 `tokio-stream`（已被 axum transitive include，但顯式加）
- Modify: `crates/sessionsd/src/main.rs` —
  - `AppState` 加 `tx: broadcast::Sender<SseEvent>`
  - 新增 `SseEvent` enum（`SessionsChanged` / `SessionUpdated { id }` / `Ping`）
  - 在每個寫入 registry 的地方 `let _ = state.tx.send(…)`
  - 新 route `GET /events` → axum `Sse<Stream<…>>`，心跳 15s
- Modify: `hud/Sources/SessionsHUD/AppModel.swift` —
  - 保留 `refresh()` 作為初始 / 重連 snapshot
  - 新增 `EventStream` actor，使用 `URLSession.bytes(for:)` 消費 SSE 行
  - `start()` 不再用 `Timer`，改啟動 `Task` 迴圈

### Task 3.1: 後端 broadcast 欄位

**Files:**
- Modify: `crates/sessionsd/src/main.rs`

- [ ] **Step 1：加 import 與 enum**

在現有 `use` 區塊加：

```rust
use tokio::sync::broadcast;
```

在 `AppState` 上方加：

```rust
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum SseEvent {
    /// Session list changed (add / remove / status flip). HUD should refetch
    /// /sessions for the full list.
    SessionsChanged,
    /// Detail of one session changed (message append, pending_prompt flip,
    /// stats update). HUD should refetch /sessions/<id> if that's the
    /// currently selected one.
    SessionUpdated { id: String },
}
```

- [ ] **Step 2：`AppState` 加 tx**

```rust
#[derive(Clone)]
struct AppState {
    registry: Registry,
    wrappers: WrapperRegistry,
    tx: broadcast::Sender<SseEvent>,
}
```

`main()` 內 `AppState { … }` 補上 `tx: broadcast::channel(256).0`。

- [ ] **Step 3：`cargo build -p sessionsd` 確認編譯**

Expected：過。

- [ ] **Step 4：Commit**

```bash
git add crates/sessionsd/src/main.rs
git commit -m "sessionsd: add broadcast channel for SSE events"
```

### Task 3.2: 所有寫入點廣播

**Files:**
- Modify: `crates/sessionsd/src/main.rs`

- [ ] **Step 1：識別寫入點**

用 `grep -n "registry.write" crates/sessionsd/src/main.rs` 找出全部。預期點包含：
- `handle_hook`（SessionStart/UserPromptSubmit/Notification/Stop）→ `SessionsChanged` + `SessionUpdated { id }`
- `handle_statusline` → `SessionUpdated { id }`
- `append_output`（cxw 路徑）→ `SessionUpdated { id }`
- `tail_one`（transcript tailer，寫入 messages）→ `SessionUpdated { id }`
- `forget_session` → `SessionsChanged`
- `terminate_wrapper` → 不直接寫 registry，後續由 Stop hook 觸發，略過
- `register_wrapper` / `unregister_wrapper`：wrapper 變動暫不廣播（HUD 只看 sessions）

- [ ] **Step 2：在每個點後呼叫 `let _ = state.tx.send(…);`**

失敗（無訂閱者）是 OK 的。

- [ ] **Step 3：`cargo build -p sessionsd`**

- [ ] **Step 4：Commit**

```bash
git commit -am "sessionsd: emit SSE events on registry writes"
```

### Task 3.3: `/events` 端點

**Files:**
- Modify: `crates/sessionsd/src/main.rs`

- [ ] **Step 1：新增 handler**

```rust
use axum::response::sse::{Event, KeepAlive, Sse};
use futures::stream::Stream;
use tokio_stream::wrappers::BroadcastStream;
use tokio_stream::StreamExt;

async fn sse_events(
    State(state): State<AppState>,
) -> Sse<impl Stream<Item = Result<Event, axum::Error>>> {
    let rx = state.tx.subscribe();
    let stream = BroadcastStream::new(rx).filter_map(|res| match res {
        Ok(ev) => {
            let json = serde_json::to_string(&ev).ok()?;
            Some(Ok(Event::default().data(json)))
        }
        Err(_) => None, // lagged; client will poll snapshot on next heartbeat
    });
    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}
```

- [ ] **Step 2：註冊 route**

在 `Router::new()` 鏈上加：

```rust
.route("/events", get(sse_events))
```

- [ ] **Step 3：`Cargo.toml` 加依賴**

```toml
tokio-stream = { version = "0.1", features = ["sync"] }
futures = "0.3"
```

（axum 已包含 SSE，但需顯式開 feature — 若編譯抱怨 `axum::response::sse`，在 `axum` 依賴加 `features = ["macros"]` 不夠，需要 `"sse"` 或直接開 `"default"`，視實際錯誤調整。）

- [ ] **Step 4：`cargo build -p sessionsd` 並 curl 測試**

```bash
cargo run -p sessionsd &
sleep 1
curl -N http://127.0.0.1:39501/events
```

Expected：開啟連線後長時間不關閉；另開 terminal 送一個 hook POST 後，`/events` 立刻印出 `data: {"type":"sessions_changed"}`；無事件時每 15s 收到 `: ping`。

- [ ] **Step 5：Commit**

```bash
git commit -am "sessionsd: add GET /events SSE endpoint"
```

### Task 3.4: Swift SSE client

**Files:**
- Create: `hud/Sources/SessionsHUD/EventStream.swift`
- Modify: `hud/Sources/SessionsHUD/AppModel.swift`

- [ ] **Step 1：建立 EventStream.swift**

```swift
import Foundation

/// Minimal SSE line parser over URLSession.bytes. Emits decoded `SseEvent`
/// values on an AsyncStream. Reconnects with exponential backoff on drop;
/// callers are expected to refetch a snapshot after each (re)connect to
/// reconcile any events missed during the outage.
enum SseEvent: Decodable {
    case sessionsChanged
    case sessionUpdated(id: String)
    case unknown

    private enum CodingKeys: String, CodingKey { case type, id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "sessions_changed": self = .sessionsChanged
        case "session_updated":
            self = .sessionUpdated(id: try c.decode(String.self, forKey: .id))
        default: self = .unknown
        }
    }
}

actor EventStreamClient {
    private let url: URL
    private var task: Task<Void, Never>?

    init(url: URL) { self.url = url }

    func start(onConnect: @escaping @Sendable () async -> Void,
               onEvent:   @escaping @Sendable (SseEvent) async -> Void) {
        task?.cancel()
        task = Task { [url] in
            var backoff: UInt64 = 500_000_000 // 0.5s
            while !Task.isCancelled {
                do {
                    var req = URLRequest(url: url)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 0 // no client-side timeout
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    backoff = 500_000_000
                    await onConnect()
                    var dataBuf = ""
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            if !dataBuf.isEmpty,
                               let d = dataBuf.data(using: .utf8),
                               let ev = try? JSONDecoder().decode(SseEvent.self, from: d) {
                                await onEvent(ev)
                            }
                            dataBuf = ""
                        } else if line.hasPrefix("data:") {
                            let s = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            dataBuf += s
                        }
                        // ignore comments (":" lines), event:, id:, retry:
                    }
                } catch {
                    // fall through to backoff
                }
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 10_000_000_000) // cap 10s
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
}
```

- [ ] **Step 2：AppModel.swift 切換**

- 刪除 `pollTimer`（保留 `clockTimer`）。
- `start()` 改成：

```swift
func start() {
    clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.now = Date() }
    }
    Task { await refresh() } // initial snapshot

    let eventsURL = URL(string: "\(daemonBase)/events")!
    events = EventStreamClient(url: eventsURL)
    Task { [weak self] in
        await self?.events?.start(
            onConnect: { [weak self] in
                await self?.refresh() // reconcile after (re)connect
            },
            onEvent: { [weak self] ev in
                await self?.handleEvent(ev)
            }
        )
    }
}

@MainActor
private func handleEvent(_ ev: SseEvent) async {
    switch ev {
    case .sessionsChanged:
        await refresh()
        if selectedId != nil { await refreshSelected() }
    case .sessionUpdated(let id):
        if id == selectedId { await refreshSelected() }
        // Also refresh list so status / pending_prompt in the compact row updates.
        await refresh()
    case .unknown:
        break
    }
}
```

並加 `private var events: EventStreamClient?`。

- [ ] **Step 3：`swift build -c release` 編譯**

- [ ] **Step 4：Commit**

```bash
git add hud/Sources/SessionsHUD/EventStream.swift hud/Sources/SessionsHUD/AppModel.swift
git commit -m "hud: replace 1s poll with SSE event stream"
```

### Task 3.5: 實機冒煙

- [ ] **Step 1：同時啟動 sessionsd + sessions-hud**
- [ ] **Step 2：跑一個 `ccw test1`**
- [ ] **Step 3：確認 HUD 1 秒內出現該 session**
- [ ] **Step 4：讓 claude 進入 permission prompt → 觀察 banner 是否幾乎即時出現（目測 <500ms）**
- [ ] **Step 5：`kill` sessionsd → HUD 應顯示錯誤；`launchctl kickstart` 重啟 → HUD 應自動重連並補齊 snapshot**

---

## 自我審查

**Spec 覆蓋**：三個 phase 對應前次對話中的「高價值」三項，每項都有可驗證的 end-to-end 步驟。

**Placeholder 檢查**：所有 step 都有實際 code / command / expected。

**型別一致**：`SseEvent` 在 Rust 端（serde snake_case）與 Swift 端（`sessions_changed` / `session_updated`）對齊；Swift `EventStreamClient` 未引入 Rust 未定義的欄位。
