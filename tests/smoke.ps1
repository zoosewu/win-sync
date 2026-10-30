# 冒煙測試：用暫存資料夾模擬 Dropbox\WinSync 與 local.json，不碰真正的 Dropbox、Documents 與排程
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1 [-WorkDir <暫存位置>]
param([string]$WorkDir = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
$repo   = Split-Path $PSScriptRoot
$tmp    = Join-Path $WorkDir "win-sync-smoke-$PID"
$data   = Join-Path $tmp 'Dropbox\WinSync'
$local  = Join-Path $tmp 'local.json'
$home2  = Join-Path $tmp 'home'
$regKey = 'HKCU:\Software\win-sync-smoke'

# $StdIn 有值時會導向子程序的輸入（選單改用編號選擇）
function Invoke-WinSync([string[]]$CmdArgs, [string[]]$StdIn, [string]$Exe = (Join-Path $repo 'win-sync.ps1')) {
    $script:LastOutput = if ($StdIn) {
        $StdIn | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exe @CmdArgs 2>&1 | Out-String
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exe @CmdArgs 2>&1 | Out-String
    }
    Write-Host $script:LastOutput
}
function Assert($Cond, [string]$Message) {
    if (-not $Cond) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}
function Read-Config { Get-Content (Join-Path $data 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Read-Local { Get-Content $local -Raw -Encoding UTF8 | ConvertFrom-Json }
$devMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -eq 1

New-Item -ItemType Directory -Force $data, "$home2\appdir", "$data\files\elsewhere" | Out-Null
Set-Content "$home2\app.conf" 'local-v1'
Set-Content "$home2\appdir\a.txt" 'dir-v1'
Set-Content "$data\files\elsewhere\e.txt" 'from-other-pc'
New-Item $regKey -Force | Out-Null
@{
    documents = $null
    links     = @(
        @{ name = 'app.conf'; title = 'App 設定' },
        @{ name = 'appdir' },
        @{ name = 'elsewhere'; title = '別台加入的'; description = '只在別台電腦設定過位置' },
        @{ name = 'unused' })
    registry  = @(@{ label = '測試值'; key = $regKey; name = 'Value'; value = 42; type = 'DWord' })
} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $data 'config.json') -Encoding UTF8
@{ links = @{ 'app.conf' = "$home2\app.conf"; appdir = "$home2\appdir"; unused = $null } } |
    ConvertTo-Json -Depth 5 | Set-Content $local -Encoding UTF8

$env:WINSYNC_DATA  = $data
$env:WINSYNC_LOCAL = $local
try {
    # 第一台：本機設定搬進 Dropbox
    Invoke-WinSync 'sync'
    Assert ((Get-Item "$home2\appdir" -Force).LinkType -eq 'Junction') '資料夾換成 junction'
    Assert (Test-Path "$data\files\appdir\a.txt") '資料夾內容搬進 Dropbox'
    Assert ((Get-ItemProperty $regKey).Value -eq 42) 'registry 已套用'
    Assert ($script:LastOutput -match '有 1 項備份尚未設定這台電腦的位置') '未設定位置的項目產生待辦（不使用的不算）'
    Assert ($script:LastOutput -match '只在別台電腦設定過位置') '待辦列出描述'
    $fileLink = (Get-Item "$home2\app.conf" -Force -ErrorAction SilentlyContinue).LinkType
    if ($devMode) {
        Assert ($fileLink -eq 'SymbolicLink') '檔案換成 symlink'
    } else {
        Assert (-not $fileLink) '未開開發人員模式：檔案連結未建立'
        Assert ($script:LastOutput -match 'App 設定 同步失敗') '未開開發人員模式：出現同步失敗待辦'
        Assert ((Get-Content "$home2\app.conf") -eq 'local-v1') '未開開發人員模式：本機檔案仍保留'
    }

    # 已在使用的電腦：本機有不同內容 → 備份後改用 Dropbox 版本
    [IO.Directory]::Delete("$home2\appdir")
    New-Item -ItemType Directory "$home2\appdir" | Out-Null
    Set-Content "$home2\appdir\a.txt" 'other-machine'
    Invoke-WinSync 'sync'
    Assert ((Get-Item "$home2\appdir" -Force).LinkType -eq 'Junction') '重新連結到 Dropbox 版本'
    Assert (@(Get-ChildItem $home2 -Filter 'appdir.win-sync-bak-*').Count -eq 1) '本機舊版已備份'

    # add：加入後立即連結；位置只寫進 local.json
    New-Item -ItemType Directory "$home2\newdir" | Out-Null
    Invoke-WinSync 'add', "$home2\newdir"
    Assert ((Get-Item "$home2\newdir" -Force).LinkType -eq 'Junction') 'add 後立即連結'
    $entry = @((Read-Config).links | Where-Object { $_.name -eq 'newdir' })[0]
    Assert ($entry -and -not ($entry.PSObject.Properties.Name -match 'path|machines')) 'config.json 不含路徑'
    Assert ((Read-Local).links.newdir -like '*\home\newdir') 'local.json 記錄位置'

    # add 已存在的名稱：改記錄這台電腦的新位置
    New-Item -ItemType Directory "$home2\alt" | Out-Null
    Invoke-WinSync 'add', "$home2\alt\newdir", 'newdir'
    Assert ((Read-Local).links.newdir -like '*\alt\newdir') 'add 同名項目：local.json 改為新位置'
    Assert ((Get-Item "$home2\alt\newdir" -Force).LinkType -eq 'Junction') 'add 同名項目：新位置已連結'
    Assert ($script:LastOutput -match '舊位置還留著連結') 'add 同名項目：提醒舊位置的連結'

    # 選單：新增備份（1 → 路徑 → 標題 → 描述 → 6 結束）
    New-Item -ItemType Directory "$home2\menudir" | Out-Null
    Set-Content "$home2\menudir\m.txt" 'menu'
    Invoke-WinSync @() @('1', "$home2\menudir", 'Menu Title', 'Menu desc', '6')
    $entry = @((Read-Config).links | Where-Object { $_.title -eq 'Menu Title' })[0]
    Assert ($entry -and $entry.description -eq 'Menu desc') '選單新增：標題與描述寫進 config.json'
    Assert ((Get-Item "$home2\menudir" -Force).LinkType -eq 'Junction') '選單新增：已連結'

    # 選單：把別台電腦加入的備份指向這台的位置（2 → 選項目 → 1 指定位置 → 路徑 → 返回 → 6 結束）
    $links = @((Read-Config).links)
    $n = [array]::IndexOf(@($links | ForEach-Object { $_.name }), 'elsewhere') + 1
    Invoke-WinSync @() @('2', "$n", '1', "$home2\here\elsewhere", "$($links.Count + 1)", '6')
    Assert ((Read-Local).links.elsewhere -like '*\here\elsewhere') '選單設定位置：寫進 local.json'
    Assert ((Get-Item "$home2\here\elsewhere" -Force).LinkType -eq 'Junction') '選單設定位置：已連結'
    Assert (Test-Path "$home2\here\elsewhere\e.txt") '選單設定位置：看得到別台的內容'

    # add-reg：記錄目前的值
    New-ItemProperty $regKey -Name Other -Value 'abc' -PropertyType String -Force | Out-Null
    Invoke-WinSync 'add-reg', ($regKey -replace '^HKCU:', 'HKEY_CURRENT_USER'), 'Other', '測試字串'
    Assert (@((Read-Config).registry | Where-Object { $_.name -eq 'Other' -and $_.value -eq 'abc' }).Count -eq 1) 'add-reg 已記錄'

    Invoke-WinSync 'status'
    Assert ($script:LastOutput -notmatch '尚未設定這台電腦的位置') '全部設定後不再提醒'

    # 更新（git）：把目前的工具做成本機的上游 repo，clone 一份安裝，上游加 commit 後執行 update
    $up   = Join-Path $tmp 'upstream'
    $inst = Join-Path $tmp 'install'
    robocopy $repo $up /E /XD .git /XF local.json /NFL /NDL /NJH /NJS /NP | Out-Null
    git -C $up init -q -b main
    git -C $up add -A
    git -C $up -c user.name=smoke -c user.email=smoke@example.com commit -qm v1
    git clone -q $up $inst
    Set-Content "$up\NEW.txt" 'v2'
    git -C $up add -A
    git -C $up -c user.name=smoke -c user.email=smoke@example.com commit -qm v2
    Invoke-WinSync 'update' -Exe "$inst\win-sync.ps1"
    Assert (Test-Path "$inst\NEW.txt") 'update：git 安裝的會更新到最新版'
    Invoke-WinSync 'update' -Exe "$inst\win-sync.ps1"
    Assert ($script:LastOutput -match '已是最新版') 'update：已是最新版'
    Set-Content "$inst\mine.txt" 'dev'
    Invoke-WinSync 'update' -Exe "$inst\win-sync.ps1"
    Assert ($script:LastOutput -match '未提交的修改') 'update：有未提交的修改時不更新'
} finally {
    Remove-Item Env:WINSYNC_DATA, Env:WINSYNC_LOCAL
    Remove-Item $regKey -Recurse -Force -ErrorAction SilentlyContinue
    # 先拆連結再刪，避免刪除時跟進連結目標
    Get-ChildItem $home2, "$home2\alt", "$home2\here" -Force -ErrorAction SilentlyContinue | Where-Object LinkType | ForEach-Object {
        if ($_.PSIsContainer) { [IO.Directory]::Delete($_.FullName) } else { [IO.File]::Delete($_.FullName) }
    }
    Remove-Item $tmp -Recurse -Force
}
