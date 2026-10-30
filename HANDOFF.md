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

## 尚未完成
- `README.md`（繁體中文）：概念與架構圖、三種情境（第一台、新電腦、現有電腦）、指令表、config.json 格式、限制（見下方）、FAQ（為什麼不需要 win-sync-data）。
- `.gitattributes`（`*.ps1 text eol=crlf`）、`git init`。使用者沒有要求 commit，commit 前要先問。
- 新電腦取得工具的方式：先 `winget install Git.Git` 再 clone，或下載 zip。若推上 GitHub，可考慮加一支 `bootstrap.ps1` 用 `irm | iex` 執行。
- 可考慮新增 `remove <name>`：把連結還原成本機檔案，並從 config 移除。

## 要寫進 README 的限制
- registry 是單向、宣告式的：在「設定」App 改的東西不會自動回寫，要用 `win-sync add-reg` 記錄。
- 同一個 App 不要在兩台電腦同時開著，否則 Dropbox 會產生 conflicted copy（status 會偵測）。
- 有些 App 存檔時會「寫暫存檔再改名」，把連結換成實體檔案；下次同步時會備份成 `.win-sync-bak-*` 再重新連結。
- 不要同步快取、資料庫、私鑰；有內建同步功能的 App（VS Code、瀏覽器）用它自己的。
- HKLM 設定需要系統管理員，背景同步會失敗並產生待辦。

## 開發小抄
重新加 BOM：

```powershell
foreach ($f in Get-ChildItem . -Recurse -Filter *.ps1) { $t=[IO.File]::ReadAllText($f.FullName); [IO.File]::WriteAllText($f.FullName,$t,(New-Object Text.UTF8Encoding $true)) }
```

用 5.1 做語法檢查：`[Management.Automation.Language.Parser]::ParseFile(path,[ref]$null,[ref]$errors)`。
