# 冒煙測試：用暫存資料夾模擬 Dropbox\WinSync，不碰真正的 Dropbox、Documents 與排程
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 [-WorkDir <暫存位置>]
param([string]$WorkDir = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
$repo   = Split-Path $PSScriptRoot
$tmp    = Join-Path $WorkDir "win-sync-smoke-$PID"
$data   = Join-Path $tmp 'Dropbox\WinSync'
$home2  = Join-Path $tmp 'home'
$regKey = 'HKCU:\Software\win-sync-smoke'

function Invoke-WinSync([string[]]$CmdArgs) {
    $script:LastOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'win-sync.ps1') @CmdArgs 2>&1 | Out-String
    Write-Host $script:LastOutput
}
$devMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -eq 1
function Assert($Cond, [string]$Message) {
    if (-not $Cond) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

New-Item -ItemType Directory -Force $data, "$home2\appdir" | Out-Null
Set-Content "$home2\app.conf" 'local-v1'
Set-Content "$home2\appdir\a.txt" 'dir-v1'
New-Item $regKey -Force | Out-Null
@{
    documents = $null
    links     = @(@{ name = 'app.conf'; path = "$home2\app.conf" }, @{ name = 'appdir'; path = "$home2\appdir" })
    registry  = @(@{ label = '測試值'; key = $regKey; name = 'Value'; value = 42; type = 'DWord' })
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $data 'config.json') -Encoding UTF8

$env:WINSYNC_DATA = $data
try {
    # 第一台：本機設定搬進 Dropbox
    Invoke-WinSync 'sync'
    Assert ((Get-Item "$home2\appdir" -Force).LinkType -eq 'Junction') '資料夾換成 junction'
    Assert (Test-Path "$data\files\appdir\a.txt") '資料夾內容搬進 Dropbox'
    Assert ((Get-ItemProperty $regKey).Value -eq 42) 'registry 已套用'
    $fileLink = (Get-Item "$home2\app.conf" -Force -ErrorAction SilentlyContinue).LinkType
    if ($devMode) {
        Assert ($fileLink -eq 'SymbolicLink') '檔案換成 symlink'
    } else {
        Assert (-not $fileLink) '未開開發人員模式：檔案連結未建立'
        Assert ($script:LastOutput -match 'app\.conf 同步失敗') '未開開發人員模式：出現同步失敗待辦'
        Assert ((Get-Content "$home2\app.conf") -eq 'local-v1') '未開開發人員模式：本機檔案仍保留'
    }

    # 已在使用的電腦：本機有不同內容 → 備份後改用 Dropbox 版本
    [IO.Directory]::Delete("$home2\appdir")
    New-Item -ItemType Directory "$home2\appdir" | Out-Null
    Set-Content "$home2\appdir\a.txt" 'other-machine'
    Invoke-WinSync 'sync'
    Assert ((Get-Item "$home2\appdir" -Force).LinkType -eq 'Junction') '重新連結到 Dropbox 版本'
    Assert (@(Get-ChildItem $home2 -Filter 'appdir.win-sync-bak-*').Count -eq 1) '本機舊版已備份'

    # add：加入後立即連結
    New-Item -ItemType Directory "$home2\newdir" | Out-Null
    Invoke-WinSync 'add', "$home2\newdir"
    Assert ((Get-Item "$home2\newdir" -Force).LinkType -eq 'Junction') 'add 後立即連結'

    # add-reg：記錄目前的值
    New-ItemProperty $regKey -Name Other -Value 'abc' -PropertyType String -Force | Out-Null
    Invoke-WinSync 'add-reg', ($regKey -replace '^HKCU:', 'HKEY_CURRENT_USER'), 'Other', '測試字串'
    $cfg = Get-Content (Join-Path $data 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert (@($cfg.registry | Where-Object { $_.name -eq 'Other' -and $_.value -eq 'abc' }).Count -eq 1) 'add-reg 已記錄'

    Invoke-WinSync 'status'
} finally {
    Remove-Item Env:WINSYNC_DATA
    Remove-Item $regKey -Recurse -Force -ErrorAction SilentlyContinue
    # 先拆連結再刪，避免刪除時跟進連結目標
    Get-ChildItem $home2 -Force | Where-Object LinkType | ForEach-Object {
        if ($_.PSIsContainer) { [IO.Directory]::Delete($_.FullName) } else { [IO.File]::Delete($_.FullName) }
    }
    Remove-Item $tmp -Recurse -Force
}
