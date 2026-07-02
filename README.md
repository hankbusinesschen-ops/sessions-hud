# Sessions HUD for Claude Code

> 一個 macOS 玻璃懸浮視窗，即時監控你所有的 Claude Code session：
> 狀態、待回覆的提示全文、quota 用量，需要你時發出通知，一鍵跳回該
> session 所在的終端機分頁。

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

## 這是什麼

如果你同時開三、四個 `claude` session 散在不同終端機分頁，你會漏掉
權限提示、忘記哪個 session 跑完了、不知道哪個快撞到 5 小時上限。

Sessions HUD 是一片浮在桌面上的原生毛玻璃面板：

- **即時 session 列表** — 依 git repo 分組，狀態點會動（執行中／等你回覆／閒置／完成）
- **Attention Bar** — 任何等你回覆的 session 釘選在最上方，琥珀色呼吸燈＋音效＋選單列「● N」徽章
- **展開詳情** — 點一列看到待回覆提示的全文、目前執行的工具、quota（ctx% / 5h% / 7d%）
- **一鍵跳回終端機** — 按「終端機」直接聚焦到該 session 所在的 Terminal.app / iTerm2 分頁，回覆就在那裡完成
- **零常駐依賴** — 沒有 daemon、沒有 port、沒有 launchd。唯一的執行程式就是這個 app

## 安裝

```bash
git clone https://github.com/hankbusinesschen-ops/sessions-hud.git
cd sessions-hud
./install.sh
```

就這樣。`install.sh` 會建置 `Sessions HUD.app`、放進 `/Applications`、
接上 Claude Code hooks 與 statusline quota tee，然後開啟 app。
之後從 Launchpad / Spotlight 搜「Sessions HUD」即可。

第一次啟動如果 hooks 還沒接上，app 內建的引導頁有「一鍵安裝」按鈕。

需求：**macOS 13+**、**Xcode Command Line Tools**（`xcode-select --install`，建置用）、**Claude Code CLI**。

### 解除安裝

```bash
./install.sh uninstall
```

## 運作原理

```
claude CLI
   │ hooks（~/.claude/settings.json）
   ▼
post-event.sh ──原子寫入──▶ ~/Library/Application Support/SessionsHUD/events/*.json
  （附加 tty、pid、終端機種類）      │
                                     │ 目錄監看（kqueue + 輪詢備援）
                                     ▼
                          Sessions HUD.app（唯一執行程式）
```

Claude Code 的每個 hook 事件被包成一個小 JSON 檔丟進 spool 資料夾，
app 監看資料夾、還原成 session 狀態。沒有網路、沒有 socket——app
沒開的時候 hooks 照樣安靜地寫檔（幾 KB），下次開啟全部補上。

session 存活判定：SessionEnd hook 為主訊號，輔以 PID 檢查與過期清掃，
所以殭屍列不會殘留。

## 疑難排解

- **HUD 是空的** — 開設定（齒輪）看診斷；或在終端機執行：
  ```bash
  "/Applications/Sessions HUD.app/Contents/MacOS/SessionsHUD" --doctor
  ```
- **quota（ctx%/5h%/7d%）不顯示** — 需要自訂的 `~/.claude/statusline-command.sh`。
  installer 會自動注入 tee；沒有該檔案的話 quota 顯示 `—`（其他功能不受影響）。
  手動貼上版本見 [`packaging/statusline-snippet.sh`](packaging/statusline-snippet.sh)。
- **「終端機」按鈕沒反應** — 系統設定 → 隱私權與安全性 → 自動化 →
  Sessions HUD → 勾選 Terminal / iTerm。tmux、SSH、IDE 內建終端沒有
  tty 資訊，按鈕會停用並顯示原因。
- **靜音** — `defaults write com.sessionshud.hud mute -bool YES`

## 開發

```bash
cd hud
swift build          # 建置
swift test           # reducer 與 spool 檔案生命週期的單元測試
swift run            # 以 debug 模式跑 HUD
scripts/make-app.sh  # 打包 Sessions HUD.app 到 dist/
```

程式碼結構（`hud/Sources/SessionsHUD/`）：

- `App/` — 進入點、玻璃面板（NSPanel + NSVisualEffectView）、選單列徽章
- `Core/` — `SessionStore`（純 reducer，可測試）、`EventSpool`（目錄監看）、
  `Liveness`（PID 批次檢查）、`HooksInstaller`（settings.json 合併與 statusline tee）
- `Views/` — 列表、列、展開詳情、onboarding、設定
- `hooks/post-event.sh` — hook → spool 的橋接 script（zsh，<50 行）

## 安全性

- 沒有任何網路監聽。事件資料夾在你的使用者目錄內，權限跟隨 macOS 預設。
- hooks 只「讀」Claude Code 給的事件 payload 並寫成本機檔案；HUD 是
  唯讀監控器，不能代替你回覆或注入任何輸入。
- `install.sh` 只改兩個檔案：`~/.claude/settings.json`（改前自動備份為
  `settings.json.sessionshud.bak`）與 `~/.claude/statusline-command.sh`
  （sentinel 註解包裹，可乾淨移除）。

## License

MIT — see [`LICENSE`](LICENSE).

## Acknowledgements

Built for and around [Claude Code](https://claude.com/claude-code) by
Anthropic. Not affiliated.
