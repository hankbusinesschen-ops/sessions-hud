# 手動驗證核對表（E2E）

在改動 HUD、daemon 或 wrapper 後，用此表快速確認行為。需本機已安裝 `claude`、hooks 與 `sessionsd`。

## 0. 環境

- [ ] 已從 repo 根目錄執行過 `./install.sh`（或至少已手動安裝 `ccw` / `sessionsd` / `sessions-hud` 與 hooks）
- [ ] `./scripts/check-sessions-hud-runtime.sh` 全數通過或僅有預期中的警告
- [ ] `cargo test --workspace` 通過
- [ ] `cd hud && swift build` 通過

## 1. Native `claude`（唯讀）

- [ ] 在終端直接執行 `claude`（非 `ccw`），在 HUD 中可看到該 session
- [ ] 進入 Chat 視圖出現黃色 read-only 橫幅，核准按鈕與底部輸入框為禁用
- [ ] 點 **Relaunch as ccw** 能開新終端執行 `ccw`（需 Automation 權限）

## 2. `ccw`（可注入）

- [ ] 在專案目錄執行 `ccw testsession`，HUD 中該列有可注入行為（底部 **Interrupt (⌃C)** / **Enter ⏎** 可用，無 lock 橫幅）
- [ ] 在 Chat 內按 **Send** 可送文字到 TUI
- [ ] 按 **Interrupt (⌃C)** 不崩潰（中斷長跑指令時使用）

## 3. 核准 / 提問

- [ ] 觸發權限或 plan 核准时，Attention bar 出現 session；必要時在 HUD 用 1/2/3 風格按鈕回覆
- [ ] 若出現 `AskUserQuestion`，選項與提交可用（僅 `ccw` session）

## 4. 結束

- [ ] 正常結束後 session 狀態變為 `done` 或自列表依規則消失（依 daemon 行為）
- [ ] 對 wrapper session 用垃圾桶確認 **Terminate** 能結束子行程

## 5. 斷線與重連

- [ ] 暫停 `sessionsd` 時 HUD 顯示斷線提示
- [ ] 恢復後 SSE 重連、列表能再次載入
