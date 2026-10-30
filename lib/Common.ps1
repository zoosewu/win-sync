# 共用工具：輸出、待辦清單、通知、路徑與 JSON

$script:Todos        = New-Object System.Collections.Generic.List[object]
$script:Planned      = 0       # status（DryRun）時「待套用」的變更數
$script:NoSummary    = $false  # true 時不顯示結尾的待辦摘要
$script:StateDir     = Join-Path $env:LOCALAPPDATA 'win-sync'
$script:LogFile      = Join-Path $script:StateDir 'win-sync.log'
$script:LastTodoFile = Join-Path $script:StateDir 'last-todo.txt'

# ---------- 紀錄與輸出 ----------

function Write-Log([string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Force $script:StateDir | Out-Null }
        if ((Test-Path -LiteralPath $script:LogFile) -and (Get-Item -LiteralPath $script:LogFile).Length -gt 1MB) {
            Remove-Item -LiteralPath $script:LogFile
        }
        Add-Content -LiteralPath $script:LogFile -Value "$(Get-Date -Format s) $Message" -Encoding UTF8
    } catch { }
}

function Write-Line([string]$Tag, [string]$Message, [ConsoleColor]$Color) {
    Write-Log "$Tag $Message"
    if (-not $script:Background) { Write-Host "  $Tag " -ForegroundColor $Color -NoNewline; Write-Host $Message }
}

function Write-Step([string]$Message) {
    Write-Log "==> $Message"
    if (-not $script:Background) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
}
function Write-Ok([string]$Message)   { Write-Line '[OK]' $Message Green }
function Write-Act([string]$Message)  { Write-Line '[->]' $Message Cyan }
function Write-Skip([string]$Message) { Write-Line '[--]' $Message DarkGray }
function Write-Warn([string]$Message) { Write-Line '[!!]' $Message Yellow }
function Write-Plan([string]$Message) { $script:Planned++; Write-Line '[->]' "（待套用）$Message" Cyan }

# ---------- 待辦：需要使用者動手的事 ----------

function Add-Todo([string]$Title, [string[]]$Steps) {
    Write-Log "TODO $Title"
    $script:Todos.Add([pscustomobject]@{ Title = $Title; Steps = @($Steps) })
}

function Format-Todos {
    $lines = @(); $i = 1
    foreach ($t in $script:Todos) {
        $lines += "$i. $($t.Title)"
        foreach ($s in $t.Steps) { $lines += "     - $s" }
        $i++
    }
    $lines
}

function Show-Todos {
    if ($script:Background) {
        if ($script:Todos.Count) {
            Set-Content -LiteralPath $script:LastTodoFile -Encoding UTF8 -Value (@("時間：$(Get-Date -Format 'yyyy-MM-dd HH:mm')") + (Format-Todos))
            Show-Toast "win-sync：有 $($script:Todos.Count) 件事需要你處理" '開啟終端機執行 win-sync status 查看步驟'
        }
        return
    }
    if (-not $script:Todos.Count) { Write-Host "`n全部完成，沒有需要你處理的事。" -ForegroundColor Green; return }
    Write-Host "`n需要你處理（$($script:Todos.Count) 件）：" -ForegroundColor Yellow
    foreach ($l in Format-Todos) { Write-Host "  $l" }
}

function Show-LastBackgroundTodos {
    if (-not (Test-Path -LiteralPath $script:LastTodoFile)) { return }
    Write-Host "`n上次登入自動同步留下的提醒：" -ForegroundColor Yellow
    Get-Content -LiteralPath $script:LastTodoFile -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
    Remove-Item -LiteralPath $script:LastTodoFile
}

function Show-Toast([string]$Title, [string]$Text) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [Security.SecurityElement]::Escape($Title)
        $b = [Security.SecurityElement]::Escape($Text)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
        # 借用 Windows PowerShell 的 AppUserModelID 發通知
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch { Write-Log "通知發送失敗：$_" }
}

function Confirm-Ask([string]$Question, [bool]$Default = $true) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "$Question $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    $ans.Trim().ToLower().StartsWith('y')
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 路徑 ----------

function Expand-PathVars([string]$Path) { [Environment]::ExpandEnvironmentVariables($Path) }

# 把絕對路徑換回 %APPDATA% 等變數，讓不同使用者名稱的電腦也能共用設定
function Compress-PathVars([string]$Path) {
    foreach ($v in 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE') {
        $val = [Environment]::GetEnvironmentVariable($v)
        if (-not $val) { continue }
        $val = $val.TrimEnd('\')
        if ($Path -ieq $val -or $Path.StartsWith("$val\", [StringComparison]::OrdinalIgnoreCase)) {
            return "%$v%" + $Path.Substring($val.Length)
        }
    }
    $Path
}

function Get-NormalPath([string]$Path) {
    if (-not $Path) { return '' }
    ($Path -replace '^\\\\\?\\|^\\\?\?\\', '').TrimEnd('\')
}
function Test-SamePath([string]$A, [string]$B) { (Get-NormalPath $A) -ieq (Get-NormalPath $B) }
function Test-PathUnder([string]$Child, [string]$Parent) {
    (Get-NormalPath $Child).StartsWith((Get-NormalPath $Parent) + '\', [StringComparison]::OrdinalIgnoreCase)
}

# 跨磁碟時 Move-Item 無法搬資料夾，改用複製後刪除
function Move-Path([string]$From, [string]$To) {
    if ([IO.Path]::GetPathRoot($From) -ieq [IO.Path]::GetPathRoot($To)) {
        Move-Item -LiteralPath $From -Destination $To
        return
    }
    Copy-Item -LiteralPath $From -Destination $To -Recurse -Force
    Remove-Item -LiteralPath $From -Recurse -Force
}

# ---------- JSON 設定 ----------

function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-Json([string]$Path, $Object) {
    $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

# 取出 JSON 物件中的陣列屬性；屬性不存在時回傳空陣列
# 注意：單一元素會被 PowerShell 展開，且 5.1 的 PSCustomObject 沒有 .Count，呼叫端要再包 @()
function Get-List($Object, [string]$Name) {
    if ($null -eq $Object) { return @() }
    @($Object.$Name | Where-Object { $null -ne $_ })
}

function Set-ConfigList($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = @($Value) }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue @($Value) }
}

# ---------- 資料位置 ----------

function Get-DataLocation {
    # WINSYNC_DATA 用於測試，直接指定資料資料夾
    if ($env:WINSYNC_DATA) {
        return [pscustomobject]@{ Root = (Split-Path $env:WINSYNC_DATA); Data = $env:WINSYNC_DATA }
    }
    $root = Get-DropboxRoot
    if (-not $root) { return $null }
    [pscustomobject]@{ Root = $root; Data = (Join-Path $root 'WinSync') }
}

function Get-Context {
    $loc = Get-DataLocation
    if (-not $loc) { return $null }
    $cfg = Join-Path $loc.Data 'config.json'
    if (-not (Test-Path -LiteralPath $cfg)) {
        Add-Todo "Dropbox 裡找不到 WinSync 設定（$cfg）" @(
            '新電腦：等 Dropbox 把 WinSync 資料夾同步下來，再執行 win-sync init',
            '第一台電腦：執行 win-sync init，回答「是第一台」來建立設定')
        return $null
    }
    [pscustomobject]@{ Root = $loc.Root; Data = $loc.Data; ConfigPath = $cfg; Config = (Read-Json $cfg); Local = (Read-LocalState) }
}

# ---------- 本機資料 ----------
# 各備份在這台電腦的位置只存在工具資料夾的 local.json：不進 Dropbox，也不進 git（.gitignore）
# links 的值是路徑；null 表示這台電腦不使用；沒有該名稱表示尚未設定

function Get-LocalStatePath {
    # WINSYNC_LOCAL 用於測試
    if ($env:WINSYNC_LOCAL) { return $env:WINSYNC_LOCAL }
    Join-Path $script:RepoRoot 'local.json'
}

function Read-LocalState {
    $p = Get-LocalStatePath
    $s = if (Test-Path -LiteralPath $p) { Read-Json $p } else { $null }
    if (-not $s) { $s = [pscustomobject]@{} }
    if (-not $s.links) { $s | Add-Member -NotePropertyName links -NotePropertyValue ([pscustomobject]@{}) -Force }
    $s
}

function Save-LocalState($State) { Write-Json (Get-LocalStatePath) $State }
