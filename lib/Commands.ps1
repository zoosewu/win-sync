# 指令進入點

function Invoke-Init {
    if (-not (Test-IsAdmin)) {
        Write-Host '初始化需要系統管理員權限，即將跳出 UAC 視窗，請按「是」。' -ForegroundColor Yellow
        try {
            Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script:Entry`"", 'init', '-PauseAtEnd')
            $script:NoSummary = $true
        } catch {
            Add-Todo '沒有取得系統管理員權限' @('在「終端機」圖示按右鍵 →「以系統管理員身分執行」', '再執行：win-sync init')
        }
        return
    }

    Write-Step 'Dropbox'
    $loc = Get-DataLocation
    if (-not $loc) {
        if (-not (Test-DropboxInstalled) -and (Confirm-Ask '要現在用 winget 安裝 Dropbox 嗎？')) {
            winget install -e --id Dropbox.Dropbox --accept-package-agreements --accept-source-agreements
            $script:Todos.Clear()
            Add-Todo 'Dropbox 已安裝，接下來請登入' @(
                '從開始功能表開啟 Dropbox 並登入',
                '新電腦：等 Dropbox 把 WinSync 資料夾同步下來（第一台電腦不用等）',
                '重新執行：win-sync init')
        }
        return
    }
    Write-Ok "Dropbox：$($loc.Root)"

    $firstMachine = $false
    if (-not (Test-Path -LiteralPath (Join-Path $loc.Data 'config.json'))) {
        Write-Warn 'Dropbox 裡還沒有 WinSync 設定'
        if (-not (Confirm-Ask '這是第一台使用 win-sync 的電腦嗎？（新電腦請選 n，等 Dropbox 同步完再執行）' $false)) {
            Add-Todo '等待 Dropbox 同步 WinSync 資料夾' @(
                "確認 Dropbox 同步完成，且 $($loc.Data) 存在",
                '若有使用「選擇性同步」，記得勾選 WinSync 資料夾',
                '重新執行：win-sync init')
            return
        }
        New-DataFolder $loc
        $firstMachine = $true
    }
    $ctx = Get-Context
    if (-not $ctx) { return }

    Write-Step '系統設定'
    if (Test-DevMode) { Write-Ok '開發人員模式' }
    else { Enable-DevMode; Write-Act '已開啟開發人員模式（之後不需系統管理員也能建立檔案連結）' }
    Register-SyncTask
    Write-Act '已設定：每次登入 2 分鐘後自動同步'
    Add-ToUserPath

    if ($firstMachine -and (Get-Command winget -ErrorAction SilentlyContinue) -and
        (Confirm-Ask '要把這台電腦目前安裝的軟體匯出成 apps.json 嗎？')) {
        Export-Apps $ctx
    }

    Invoke-SyncCore $ctx -Interactive -SkipSetupCheck -SkipApps
    Install-MissingApps $ctx -Ask
}

# 第一台電腦：由範本建立 Dropbox\WinSync，並以這台電腦目前的狀態為準
function New-DataFolder($Loc) {
    Write-Step '建立 WinSync 資料夾（第一台電腦）'
    New-Item -ItemType Directory -Force $Loc.Data | Out-Null
    $tpl = Join-Path $script:RepoRoot 'templates'
    $cfg = Read-Json (Join-Path $tpl 'config.json')

    $docs = Get-DocumentsPath
    if (Test-PathUnder $docs $Loc.Root) {
        $cfg.documents = (Get-NormalPath $docs).Substring((Get-NormalPath $Loc.Root).Length + 1)
        Write-Ok "Documents 已在 Dropbox 內：$docs"
    } elseif (Confirm-Ask "Documents 目前在 $docs，要改放到 Dropbox\Documents 並同步嗎？") {
        $cfg.documents = 'Documents'
    } else {
        $cfg.documents = $null
    }

    # 範本的 path 只是第一台電腦的預設位置：存在的才加入，位置寫進 local.json，不寫進 config.json
    $local = Read-LocalState
    $links = @(foreach ($l in Get-List $cfg 'links') {
        $p = Expand-PathVars $l.path
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $local.links | Add-Member -NotePropertyName $l.name -NotePropertyValue $p -Force
        $entry = [pscustomobject]@{ name = $l.name; title = $l.title; description = $l.description }
        if (Test-Path -LiteralPath $p -PathType Leaf) { $entry | Add-Member -NotePropertyName fileName -NotePropertyValue (Split-Path $p -Leaf) }
        $entry
    })
    Set-ConfigList $cfg 'links' $links
    Save-LocalState $local

    # 範本列出的 Windows 設定改記錄這台電腦目前的值，這台不會被改動
    $captured = @(foreach ($r in Get-List $cfg 'registry') {
        $cur = Get-RegValue $r.key $r.name
        if ($cur) { $r.value = $cur.Value; $r.type = $cur.Type; $r }
    })
    Set-ConfigList $cfg 'registry' $captured

    Write-Json (Join-Path $Loc.Data 'config.json') $cfg
    Copy-Item -LiteralPath (Join-Path $tpl 'apps.json') -Destination (Join-Path $Loc.Data 'apps.json')
    Write-Act "已建立 $($Loc.Data)"
}

function Invoke-SyncCore {
    param($Ctx, [switch]$DryRun, [switch]$Interactive, [switch]$SkipSetupCheck, [switch]$SkipApps)
    if (-not $SkipSetupCheck) { Test-Setup }
    Sync-Documents $Ctx -DryRun:$DryRun
    Sync-Links $Ctx -DryRun:$DryRun -Interactive:$Interactive
    Sync-Registry $Ctx -DryRun:$DryRun
    Test-DropboxFiles $Ctx
    if (-not $SkipApps) { Test-Apps $Ctx }
    if ($DryRun -and $script:Planned) {
        Add-Todo "有 $script:Planned 項變更尚未套用（上方標「待套用」的項目）" @('執行：win-sync sync')
    }
}

function Invoke-Sync {
    # 新版在下次執行時才生效，這次仍用目前載入的程式同步
    if ($script:Background) { Invoke-AutoUpdate }
    $ctx = Get-Context
    if ($ctx) { Invoke-SyncCore $ctx }
}

function Invoke-Status {
    Show-LastBackgroundTodos
    $ctx = Get-Context
    if ($ctx) { Invoke-SyncCore $ctx -DryRun }
}

function Invoke-Add([string[]]$Arguments) {
    if (-not $Arguments.Count -or -not $Arguments[0]) {
        Write-Host '用法：win-sync add <檔案或資料夾路徑> [名稱]'
        Write-Host '例如：win-sync add "%USERPROFILE%\.gitconfig"'
        Write-Host '別台電腦已加入的備份，指定它的名稱就會記錄這台電腦的位置：win-sync add "D:\Tools\A\config.ini" config.ini'
        Write-Host '也可以直接執行 win-sync 開啟選單操作'
        $script:NoSummary = $true
        return
    }
    $ctx = Get-Context
    if (-not $ctx) { return }
    $full = [IO.Path]::GetFullPath((Expand-PathVars $Arguments[0]))
    $same = Find-LinkByPath $ctx $full
    if ($same) { Write-Warn "已在備份清單中：$full（$(Get-LinkLabel $same)）"; return }
    if (-not (Test-Path -LiteralPath $full)) { Write-Warn "目前不存在：$full（之後產生時，下次同步會自動連結）" }

    $existing = $null
    if ($Arguments.Count -ge 2) { $existing = @(Get-List $ctx.Config 'links' | Where-Object { $_.name -ieq $Arguments[1] })[0] }
    if ($existing) {
        # 已有同名項目：只記錄這台電腦的位置，內容沿用 Dropbox 上的那一份
        Assert-LinkType $ctx $existing $full
        Set-LinkLocation $ctx $existing $full
        Write-Act "已記錄 $(Get-LinkLabel $existing) 在這台電腦的位置：$full"
    } else {
        $name = if ($Arguments.Count -ge 2) { $Arguments[1] } else { $null }
        $existing = New-Backup $ctx $full $name '' $name
    }
    Sync-Links $ctx -Only $existing.name
}

function Invoke-Update { Update-Self }

function Invoke-Apps {
    $ctx = Get-Context
    if ($ctx) { Install-MissingApps $ctx }
}

function Invoke-ExportApps {
    $ctx = Get-Context
    if ($ctx) { Export-Apps $ctx }
}

function Show-Help {
    $script:NoSummary = $true
    Write-Host @'
win-sync：用 Dropbox 同步 Windows 設定、App 設定檔、Documents 與軟體

用法：win-sync <指令> [參數]

  （不加指令）                開啟互動式選單：新增備份、設定這台電腦的位置、同步
  init                      新電腦或第一次使用。檢查／安裝 Dropbox、開啟開發人員模式、
                             設定登入自動同步、套用所有設定、安裝軟體（會要求系統管理員）
  status                     檢查狀態並列出需要你處理的事，不做任何修改
  sync                       立即同步（每次登入也會自動執行）
  add <路徑> [名稱]           把 App 設定檔或資料夾加入備份；名稱已存在時，
                             改為記錄它在這台電腦的位置
  add-reg <機碼> <值名稱> [說明]
                             把這台電腦目前的某個 Windows 設定加入同步
                             （機碼可直接從登錄編輯程式的網址列複製）
  apps                       安裝 apps.json 中尚未安裝的軟體
  export-apps                把這台電腦已安裝的軟體併入 apps.json
  update                     從 GitHub 更新 win-sync 本身（登入時的背景同步每天也會自動檢查；
                             在 local.json 加上 "autoUpdate": false 可關閉自動更新）
  help                       顯示本說明

資料：Dropbox\WinSync（同步）、工具資料夾\local.json（這台電腦的位置，不同步）
紀錄：%LOCALAPPDATA%\win-sync\win-sync.log
'@
}
