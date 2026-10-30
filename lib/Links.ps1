# App 設定檔連結（Mackup 模式）：設定本體放在 Dropbox\WinSync\files\<name>，原位置換成連結

function New-SymbolicFileLink([string]$Link, [string]$Target) {
    if (-not ('WinSync.Native' -as [type])) {
        Add-Type -Namespace WinSync -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
[return: MarshalAs(UnmanagedType.I1)]
public static extern bool CreateSymbolicLink(string lpSymlinkFileName, string lpTargetFileName, int dwFlags);
'@
    }
    # 回傳值是 1 byte 的 BOOLEAN，不是 4 bytes 的 BOOL，所以要用 I1，否則會讀到垃圾值而一律為 true
    # 0x2 = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE：開發人員模式下不需系統管理員
    # （Windows PowerShell 5.1 的 New-Item -ItemType SymbolicLink 不帶這個旗標）
    if (-not [WinSync.Native]::CreateSymbolicLink($Link, $Target, 0x2)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "無法建立檔案連結（$((New-Object ComponentModel.Win32Exception $code).Message)）"
    }
}

function New-Link([string]$Local, [string]$Store) {
    $parent = Split-Path $Local
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }
    if (Test-Path -LiteralPath $Store -PathType Container) {
        New-Item -ItemType Junction -Path $Local -Value $Store | Out-Null   # junction 不需任何權限
    } else {
        try {
            New-SymbolicFileLink $Local $Store
        } catch {
            # 本機檔此時已搬走或刪掉，先放一份複本回去，讓 App 還能正常使用
            Copy-Item -LiteralPath $Store -Destination $Local
            throw
        }
    }
}

# 只移除連結本身，不碰目標內容
function Remove-Link($Item) {
    if ($Item.PSIsContainer) { [IO.Directory]::Delete($Item.FullName) } else { [IO.File]::Delete($Item.FullName) }
}

function Backup-Path([string]$Path) {
    $bak = "$Path.win-sync-bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Move-Item -LiteralPath $Path -Destination $bak
    $bak
}

function Test-SameFile([string]$A, [string]$B) {
    (Test-Path -LiteralPath $A -PathType Leaf) -and (Test-Path -LiteralPath $B -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $A).Hash -eq (Get-FileHash -LiteralPath $B).Hash)
}

function Find-Backups([string]$Local, [string]$Name, [string]$FilesDir) {
    $hits = @()
    $parent = Split-Path $Local
    if (Test-Path -LiteralPath $parent) {
        $hits += @(Get-ChildItem -LiteralPath $parent -Force -Filter "$(Split-Path $Local -Leaf).win-sync-bak-*")
    }
    if (Test-Path -LiteralPath $FilesDir) {
        $hits += @(Get-ChildItem -LiteralPath $FilesDir -Force -Filter "$Name.win-sync-bak-*")
    }
    if ($hits.Count) {
        Add-Todo "$Name：有 $($hits.Count) 份舊版備份，確認不需要後可刪除" @($hits | ForEach-Object { $_.FullName })
    }
}

function Sync-Links {
    param($Ctx, [switch]$DryRun, [switch]$Interactive)
    Write-Step 'App 設定檔連結'
    $links = @(Get-List $Ctx.Config 'links')
    if (-not $links.Count) { Write-Skip '尚未設定任何連結（用 win-sync add <路徑> 新增）'; return }
    $filesDir = Join-Path $Ctx.Data 'files'
    foreach ($l in $links) {
        try {
            Sync-OneLink $l $filesDir -DryRun:$DryRun -Interactive:$Interactive
        } catch {
            Write-Warn "$($l.name)：$($_.Exception.Message)"
            Add-Todo "$($l.name) 同步失敗：$($_.Exception.Message)" @(
                '若該 App 正在執行，先關閉它再執行 win-sync sync',
                '若是權限問題，以系統管理員執行 win-sync init（會開啟開發人員模式）')
        }
    }
}

function Sync-OneLink {
    param($Link, [string]$FilesDir, [switch]$DryRun, [switch]$Interactive)
    $name     = $Link.name
    $local    = Expand-PathVars $Link.path
    $store    = Join-Path $FilesDir $name
    $item     = Get-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
    $hasStore = Test-Path -LiteralPath $store

    if ($DryRun) { Find-Backups $local $name $FilesDir }

    if ($item -and $item.LinkType) {
        $target = @($item.Target)[0]
        if (Test-SamePath $target $store) { Write-Ok $name; return }
        if ($DryRun) { Write-Plan "$name：重新連結（目前指向 $target）"; return }
        Remove-Link $item
        $item = $null
    }

    if (-not $item -and -not $hasStore) {
        Write-Skip "$name：本機與 Dropbox 都沒有（App 尚未安裝或尚未產生設定）"
        return
    }

    if ($item -and -not $hasStore) {
        # 第一台：把本機設定搬進 Dropbox
        if ($DryRun) { Write-Plan "$name：把本機設定搬進 Dropbox 並建立連結"; return }
        if (-not (Test-Path -LiteralPath $FilesDir)) { New-Item -ItemType Directory -Force $FilesDir | Out-Null }
        Move-Path $local $store
        Write-Act "$name：本機設定已搬進 Dropbox"
    } elseif ($item) {
        # 已在使用的電腦：兩邊都有
        if ($DryRun) { Write-Plan "$name：本機與 Dropbox 都有，改用 Dropbox 版本（本機版備份）"; return }
        if (Test-SameFile $local $store) {
            Remove-Item -LiteralPath $local -Force
        } elseif ($Interactive -and (Confirm-Ask "  [??] $name：本機與 Dropbox 版本不同，要改用「本機」版本嗎？（n = 用 Dropbox 版本）" $false)) {
            $bak = Backup-Path $store
            Move-Path $local $store
            Add-Todo "$name：已改用本機版本" @("Dropbox 上的舊版備份在：$bak", '確認不需要後可刪除')
        } else {
            $bak = Backup-Path $local
            Add-Todo "$name：本機版本與 Dropbox 不同，已改用 Dropbox 版本" @(
                "本機舊版備份在：$bak",
                "若有需要的內容，手動合併到 $store",
                '確認不需要後可刪除備份')
        }
    } elseif ($DryRun) {
        Write-Plan "$name：建立連結"
        return
    }

    New-Link $local $store
    Write-Act "$name：已連結 → $store"
}

# 依路徑產生 files\ 底下的名稱；撞名時加上上層資料夾名
function New-LinkName($Ctx, [string]$FullPath) {
    $used = @(Get-List $Ctx.Config 'links' | ForEach-Object { $_.name })
    $leaf = (Split-Path $FullPath -Leaf).TrimStart('.')
    $name = $leaf
    if ($used -contains $name) { $name = "$(Split-Path (Split-Path $FullPath) -Leaf)-$leaf" }
    $n = 2; $base = $name
    while ($used -contains $name) { $name = "$base-$n"; $n++ }
    $name
}
