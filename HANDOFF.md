# 交接（2026-10-29）

## 使用者需求
- 已經用 Dropbox 同步 Documents。
- 希望在新電腦或現有電腦上跑一支腳本完成初始化，之後自動同步。
- 需要使用者動手的步驟，要立刻提示怎麼做。
- 曾問「需要 win-sync-data 嗎？」。結論是不需要：資料放在 `Dropbox\WinSync`，不另開 repo（理由見 CLAUDE.md）。

## 已完成
- 指令：init、status、sync、add、add-reg、apps、export-apps、help（見 `lib/Commands.ps1`）。
- init 流程：
  - 不是系統管理員時，自我提升權限（UAC）。
  - 檢查 Dropbox，沒裝就詢問要不要用 winget 安裝。
  - 判斷是不是第一台電腦。第一台由 `templates/` 建立資料，registry 項目改記錄本機目前的值，這台不會被改動。
  - 開啟開發人員模式、註冊登入排程、把工具加入 PATH。
  - 同步：本機與 Dropbox 版本不同時，互動式詢問要用哪一版。
  - 安裝缺少的軟體。
- 冒煙測試 `tests/smoke.ps1`：第一台入庫、junction、registry 套用、第二台備份並重新連結、add、add-reg 都 PASS。

## 已修的 bug（2026-10-29）
- **檔案 symlink 沒建出來卻顯示「已連結」**：`CreateSymbolicLink` 的回傳值加上 `[return: MarshalAs(UnmanagedType.I1)]`。
  另外，檔案連結失敗時，`New-Link` 會把 Dropbox 版複製回原位再 throw，避免本機設定檔消失。
- smoke 把 SKIP 改成斷言：沒開開發人員模式時，必須沒有連結、出現 `app.conf 同步失敗` 待辦、本機檔案還在。開發機（未開開發人員模式）上全部 PASS。
- 注意：已載入的 `WinSync.Native` 型別無法在同一個 process 內重新定義。smoke 每次呼叫都開新 process，所以沒影響。
- 小瑕疵（未修）：連結失敗後，status 會顯示「本機與 Dropbox 都有，改用 Dropbox 版本（本機版備份）」。實際上兩邊內容相同時只會刪除重連，不會產生備份。

- `README.md`、`.gitattributes`、git repo（遠端 `https://github.com/zoosewu/win-sync`，分支 `main`）。

## 尚未完成
- 加一支 `bootstrap.ps1`，讓新電腦用 `irm https://raw.githubusercontent.com/zoosewu/win-sync/main/bootstrap.ps1 | iex` 一行完成安裝。目前 README 寫的是先裝 git 再 clone。
- 可考慮新增 `remove <name>`：把連結還原成本機檔案，並從 config 移除。README 的 FAQ 目前寫的是手動步驟，做完要一起更新。

## 開發小抄
重新加 BOM：

```powershell
foreach ($f in Get-ChildItem . -Recurse -Filter *.ps1) { $t=[IO.File]::ReadAllText($f.FullName); [IO.File]::WriteAllText($f.FullName,$t,(New-Object Text.UTF8Encoding $true)) }
```

用 5.1 做語法檢查：`[Management.Automation.Language.Parser]::ParseFile(path,[ref]$null,[ref]$errors)`。
