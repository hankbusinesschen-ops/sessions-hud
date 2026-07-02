# Runtime 檢查

專案根目錄執行：

```bash
chmod +x scripts/check-sessions-hud-runtime.sh   # 只需一次
./scripts/check-sessions-hud-runtime.sh
```

檢查項目包含：`ccw` / `sessionsd` / `sessions-hud` 是否在 `PATH`、本機 `39501/health`、Claude `settings.json` 是否已併入 `post-event.sh` hooks、以及 `statusline-command.sh` 是否已接入 usage tee。

與 [README.md](../README.md) 的 Troubleshooting 一併使用。
