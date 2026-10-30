# CLAUDE.md

win-sync：用 Dropbox 同步 Windows 設定、App 設定檔、Documents 與軟體清單（Windows 版的 Mackup 加強版）。
目前進度與待辦見 `HANDOFF.md`。

## 架構
- **工具（本 repo，git）**：`win-sync.ps1` 是進入點，`lib/*.ps1` 會被 dot-source 進來，`win-sync.cmd` 用來繞過 ExecutionPolicy。
- **資料（`Dropbox\WinSync`，不進 git）**：`config.json`（documents／links／registry）、`apps.json`（winget export 格式）、`files\`（設定檔本體）。
  links 只記錄名稱、標題、描述；各電腦的位置存在工具資料夾的 `local.json`（gitignore、不同步）。
- **選單**：`win-sync` 不加指令時開啟（`lib/Menu.ps1`）。輸入被導向時改用編號選擇，smoke 用這個方式測試。
  不另外開 win-sync-data repo，因為即時同步靠 Dropbox，個人資料也不該進工具 repo。
- **自動同步**：init 會註冊排程工作 `win-sync`，登入 2 分鐘後執行 `sync -Background`；有待辦時發 Windows toast，並寫入 `%LOCALAPPDATA%\win-sync\last-todo.txt`，下次執行 `status` 時顯示。
- **連結**：資料夾用 junction（不需權限）。檔案用 CreateSymbolicLink 加上 flag 0x2，開發人員模式下不需系統管理員。

## 慣例
- **必須相容 Windows PowerShell 5.1**（新電腦不一定有 pwsh），所以不能用三元運算子、`??` 等語法。
- **.ps1 一律存成 UTF-8 with BOM**，否則 5.1 讀到的中文會是亂碼。用 Write／Edit 改完後要重新加 BOM（做法見 HANDOFF.md）。
- **函式回傳的陣列在呼叫端要包 `@()`**：單一元素會被展開，而 5.1 的 PSCustomObject 沒有 `.Count`。
- **使用者訊息、註解都用繁體中文**。需要使用者動手的事一律用 `Add-Todo 標題 @(步驟...)`，最後由 `Show-Todos` 統一列出。
- **status 是 DryRun**：只用 `Write-Plan` 輸出，不修改任何東西。
- **測試**：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 [-WorkDir <暫存>]`。用環境變數 `WINSYNC_DATA`、`WINSYNC_LOCAL` 指向假的資料夾與 local.json，不會碰到真正的 Dropbox、Documents 或排程。
- **不要在開發機上直接跑 `init`**：它會改 Documents 位置、開發人員模式和排程。
