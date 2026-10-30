# App 設定檔連結（Mackup 模式）：設定本體放在 Dropbox\WinSync\files\<name>，原位置換成連結
# config.json 的 links 只記錄名稱、標題、描述（會同步）；這台電腦的位置記在 local.json（不同步）

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

function Find-Backups([string]$Local, [string]$Name, [string]$Label, [string]$FilesDir) {
    $hits = @()
    $parent = Split-Path $Local
    if (Test-Path -LiteralPath $parent) {
        $hits += @(Get-ChildItem -LiteralPath $parent -Force -Filter "$(Split-Path $Local -Leaf).win-sync-bak-*")
    }
    if (Test-Path -LiteralPath $FilesDir) {
        $hits += @(Get-ChildItem -LiteralPath $FilesDir -Force -Filter "$Name.win-sync-bak-*")
    }
    if ($hits.Count) {
        Add-Todo "$Label：有 $($hits.Count) 份舊版備份，確認不需要後可刪除" @($hits | ForEach-Object { $_.FullName })
    }
}

# ---------- 備份項目與這台電腦的位置 ----------

function Get-LinkLabel($Link) {
    if ($Link.title) { return $Link.title }
    $Link.name
}

function Get-LinkStore($Ctx, $Link) { Join-Path (Join-Path $Ctx.Data 'files') $Link.name }

# 這台電腦的狀態：set（已設定位置）、ignored（這台不使用）、unset（尚未設定）
function Get-LinkState($Ctx, $Link) {
    $p = $Ctx.Local.links.PSObject.Properties[$Link.name]
    if (-not $p) { return 'unset' }
    if ($p.Value) { return 'set' }
    'ignored'
}

function Get-LinkPath($Ctx, $Link) {
    $p = $Ctx.Local.links.PSObject.Properties[$Link.name]
    if ($p -and $p.Value) { return Expand-PathVars $p.Value }
    $null
}

# 這台電腦上已指向 $Path 的備份項目
function Find-LinkByPath($Ctx, [string]$Path) {
    @(Get-List $Ctx.Config 'links' | Where-Object { $p = Get-LinkPath $Ctx $_; $p -and (Test-SamePath $p $Path) })[0]
}

# 位置和 Dropbox 上的內容類型（檔案／資料夾）不同時丟出錯誤
function Assert-LinkType($Ctx, $Link, [string]$Path) {
    $store = Get-LinkStore $Ctx $Link
    if (-not (Test-Path -LiteralPath $Path) -or -not (Test-Path -LiteralPath $store)) { return }
    $storeIsDir = Test-Path -LiteralPath $store -PathType Container
    if ($storeIsDir -ne (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$(Get-LinkLabel $Link) 在 Dropbox 上是$(if ($storeIsDir) { '資料夾' } else { '檔案' })，和 $Path 的類型不同"
    }
}

# 記錄這台電腦的位置（$Path 為 $null 表示這台不使用），並提醒舊位置留下的連結
function Set-LinkLocation($Ctx, $Link, $Path) {
    $old = Get-LinkPath $Ctx $Link
    $Ctx.Local.links | Add-Member -NotePropertyName $Link.name -NotePropertyValue $Path -Force
    Save-LocalState $Ctx.Local
    if ($old -and -not ($Path -and (Test-SamePath $old $Path))) {
        $item = Get-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType) {
            Add-Todo "$(Get-LinkLabel $Link)：舊位置還留著連結" @("$old 仍指向 Dropbox，若不再使用可以刪除（只會刪掉連結，不影響 Dropbox 上的內容）")
        }
    }
}

# 新增備份項目：標題、描述寫進 config.json（同步），位置寫進 local.json（只在這台）
function New-Backup($Ctx, [string]$Path, [string]$Title, [string]$Description, [string]$Name) {
    if (-not $Name) { $Name = New-LinkName $Ctx $Path }
    if (-not $Title) { $Title = $Name }
    $entry = [pscustomobject]@{ name = $Name; title = $Title; description = $Description }
    # 檔案記下原本的檔名，別台電腦指定資料夾時可以沿用
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $entry | Add-Member -NotePropertyName fileName -NotePropertyValue (Split-Path $Path -Leaf)
    }
    Set-ConfigList $Ctx.Config 'links' (@(Get-List $Ctx.Config 'links') + $entry)
    Write-Json $Ctx.ConfigPath $Ctx.Config
    Set-LinkLocation $Ctx $entry $Path
    Write-Act "已加入備份：$Title → $Path"
    $entry
}

# ---------- 同步 ----------

function Sync-Links {
    param($Ctx, [switch]$DryRun, [switch]$Interactive, [string[]]$Only)
    Write-Step 'App 設定檔連結'
    $links = @(Get-List $Ctx.Config 'links')
    if (-not $links.Count) { Write-Skip '尚未設定任何備份（執行 win-sync 開啟選單新增）'; return }
    $filesDir = Join-Path $Ctx.Data 'files'
    $unset = @()
    foreach ($l in $links) {
        if ($Only -and $Only -notcontains $l.name) { continue }
        $label = Get-LinkLabel $l
        $state = Get-LinkState $Ctx $l
        if ($state -eq 'unset') { Write-Skip "$label：尚未設定這台電腦的位置"; $unset += $l; continue }
        if ($state -eq 'ignored') { Write-Skip "$label：這台電腦不使用"; continue }
        try {
            Sync-OneLink $Ctx $l $filesDir -DryRun:$DryRun -Interactive:$Interactive
        } catch {
            Write-Warn "$label：$($_.Exception.Message)"
            Add-Todo "$label 同步失敗：$($_.Exception.Message)" @(
                '若該 App 正在執行，先關閉它再執行 win-sync sync',
                '若是權限問題，以系統管理員執行 win-sync init（會開啟開發人員模式）')
        }
    }
    if ($unset.Count) {
        $steps = @($unset | ForEach-Object { if ($_.description) { "$(Get-LinkLabel $_)：$($_.description)" } else { Get-LinkLabel $_ } })
        $steps += '執行 win-sync 開啟選單 →「設定這台電腦的位置」（不需要的選「這台電腦不使用」）'
        Add-Todo "有 $($unset.Count) 項備份尚未設定這台電腦的位置" $steps
    }
}

function Sync-OneLink {
    param($Ctx, $Link, [string]$FilesDir, [switch]$DryRun, [switch]$Interactive)
    $name     = $Link.name
    $label    = Get-LinkLabel $Link
    $local    = Get-LinkPath $Ctx $Link
    $store    = Join-Path $FilesDir $name
    $item     = Get-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
    $hasStore = Test-Path -LiteralPath $store

    if ($DryRun) { Find-Backups $local $name $label $FilesDir }

    if ($item -and $item.LinkType) {
        $target = @($item.Target)[0]
        if (Test-SamePath $target $store) { Write-Ok $label; return }
        if ($DryRun) { Write-Plan "$label：重新連結（目前指向 $target）"; return }
        Remove-Link $item
        $item = $null
    }

    if (-not $item -and -not $hasStore) {
        Write-Skip "$label：本機與 Dropbox 都沒有（App 尚未安裝或尚未產生設定）"
        return
    }

    if ($item -and -not $hasStore) {
        # 第一台：把本機設定搬進 Dropbox
        if ($DryRun) { Write-Plan "$label：把本機設定搬進 Dropbox 並建立連結"; return }
        if (-not (Test-Path -LiteralPath $FilesDir)) { New-Item -ItemType Directory -Force $FilesDir | Out-Null }
        Move-Path $local $store
        Write-Act "$label：本機設定已搬進 Dropbox"
    } elseif ($item) {
        # 已在使用的電腦：兩邊都有
        if ($DryRun) { Write-Plan "$label：本機與 Dropbox 都有，改用 Dropbox 版本（本機版備份）"; return }
        if (Test-SameFile $local $store) {
            Remove-Item -LiteralPath $local -Force
        } elseif ($Interactive -and (Confirm-Ask "  [??] $label：本機與 Dropbox 版本不同，要改用「本機」版本嗎？（n = 用 Dropbox 版本）" $false)) {
            $bak = Backup-Path $store
            Move-Path $local $store
            Add-Todo "$label：已改用本機版本" @("Dropbox 上的舊版備份在：$bak", '確認不需要後可刪除')
        } else {
            $bak = Backup-Path $local
            Add-Todo "$label：本機版本與 Dropbox 不同，已改用 Dropbox 版本" @(
                "本機舊版備份在：$bak",
                "若有需要的內容，手動合併到 $store",
                '確認不需要後可刪除備份')
        }
    } elseif ($DryRun) {
        Write-Plan "$label：建立連結"
        return
    }

    New-Link $local $store
    Write-Act "$label：已連結 → $store"
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
