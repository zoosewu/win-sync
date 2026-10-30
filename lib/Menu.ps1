# 互動式選單（win-sync 不加指令時開啟）：新增備份、設定這台電腦的位置、同步
# 輸入被導向時（例如測試）改用編號選擇，不用方向鍵

function Test-InputRedirected { [Console]::IsInputRedirected }

# 回傳選到的索引；Esc 或無效輸入回傳 -1
function Select-Menu([string]$Title, [string[]]$Items, [int]$Index = 0) {
    if (Test-InputRedirected) {
        Write-Host "`n$Title"
        for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host "  $($i + 1). $($Items[$i])" }
        $n = 0
        if ([int]::TryParse((Read-Host '請輸入編號'), [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $n - 1 }
        return -1
    }
    while ($true) {
        Clear-Host
        Write-Host $Title -ForegroundColor Cyan
        Write-Host '（↑↓ 選擇、Enter 確定、Esc 返回）' -ForegroundColor DarkGray
        for ($i = 0; $i -lt $Items.Count; $i++) {
            if ($i -eq $Index) { Write-Host "  > $($Items[$i])" -ForegroundColor Black -BackgroundColor Cyan }
            else { Write-Host "    $($Items[$i])" }
        }
        switch ([Console]::ReadKey($true).Key) {
            'UpArrow'   { $Index = ($Index - 1 + $Items.Count) % $Items.Count }
            'DownArrow' { $Index = ($Index + 1) % $Items.Count }
            'Enter'     { return $Index }
            'Escape'    { return -1 }
        }
    }
}

function Clear-MenuScreen([string]$Title) {
    if (-not (Test-InputRedirected)) { Clear-Host }
    Write-Host $Title -ForegroundColor Cyan
}

# 讀取路徑：去掉拖曳檔案進視窗時帶的引號、展開環境變數；留空回傳 $null
function Read-PathInput([string]$Prompt) {
    $raw = "$(Read-Host $Prompt)".Trim().Trim('"')
    if (-not $raw) { return $null }
    [IO.Path]::GetFullPath((Expand-PathVars $raw))
}

# 每個動作結束：列出待辦，等使用者看完再回選單
function Complete-MenuAction {
    Show-Todos
    $script:Todos.Clear()
    $script:Planned = 0
    if (-not (Test-InputRedirected)) { Read-Host "`n按 Enter 返回選單" | Out-Null }
}

function Invoke-Menu {
    $script:NoSummary = $true
    while ($true) {
        $ctx = Get-Context
        if (-not $ctx) { $script:NoSummary = $false; return }
        $unset = @(Get-List $ctx.Config 'links' | Where-Object { (Get-LinkState $ctx $_) -eq 'unset' }).Count
        $locate = if ($unset) { "設定這台電腦的位置（$unset 項尚未設定）" } else { '設定這台電腦的位置' }
        $choice = Select-Menu "win-sync（這台電腦：$env:COMPUTERNAME）" @('新增備份', $locate, '立即同步', '檢查狀態', '檢查更新', '結束')
        if ($choice -lt 0 -or $choice -eq 5) { return }
        try {
            switch ($choice) {
                0 { Invoke-MenuAdd $ctx }
                1 { Invoke-MenuLocate $ctx }
                2 { Invoke-SyncCore $ctx -Interactive; Complete-MenuAction }
                3 { Invoke-SyncCore $ctx -DryRun; Complete-MenuAction }
                4 { Update-Self; Complete-MenuAction }
            }
        } catch {
            Write-Log "ERROR $($_ | Out-String)"
            Add-Todo "執行時發生錯誤：$($_.Exception.Message)" @("完整紀錄：$script:LogFile")
            Complete-MenuAction
        }
    }
}

function Invoke-MenuAdd($Ctx) {
    Clear-MenuScreen '新增備份'
    $path = Read-PathInput '要備份的檔案或資料夾路徑（可以直接把檔案拖進視窗；留空返回）'
    if (-not $path) { return }
    $same = Find-LinkByPath $Ctx $path
    if ($same) { Write-Warn "已在備份清單中：$(Get-LinkLabel $same)"; Complete-MenuAction; return }
    if (-not (Test-Path -LiteralPath $path)) { Write-Warn "找不到：$path"; Complete-MenuAction; return }

    $leaf  = Split-Path $path -Leaf
    $title = "$(Read-Host "標題（留空使用「$leaf」）")".Trim()
    if (-not $title) { $title = $leaf }
    $desc  = "$(Read-Host '描述（可留空）')".Trim()
    $entry = New-Backup $Ctx $path $title $desc
    Sync-Links $Ctx -Only $entry.name -Interactive
    Complete-MenuAction
}

function Invoke-MenuLocate($Ctx) {
    $index = 0
    while ($true) {
        $links = @(Get-List $Ctx.Config 'links')
        if (-not $links.Count) { Write-Skip '還沒有任何備份，先用「新增備份」加入'; Complete-MenuAction; return }
        $items = @(foreach ($l in $links) {
            $state = Get-LinkState $Ctx $l
            if ($state -eq 'set') { "[已設定] $(Get-LinkLabel $l) → $(Get-LinkPath $Ctx $l)" }
            elseif ($state -eq 'ignored') { "[不使用] $(Get-LinkLabel $l)" }
            else { "[未設定] $(Get-LinkLabel $l)" }
        }) + '返回'
        $i = Select-Menu '設定這台電腦的位置（別台電腦加入的備份，在這裡指定這台電腦的路徑）' $items $index
        if ($i -lt 0 -or $i -ge $links.Count) { return }
        $index = $i
        Edit-LinkLocation $Ctx $links[$i]
    }
}

function Edit-LinkLocation($Ctx, $Link) {
    $label = Get-LinkLabel $Link
    $store = Get-LinkStore $Ctx $Link
    $kind  = if (Test-Path -LiteralPath $store -PathType Container) { '資料夾' } elseif (Test-Path -LiteralPath $store) { '檔案' } else { '' }
    $cur   = Get-LinkPath $Ctx $Link
    $info  = "$label" +
        $(if ($Link.description) { "`n  描述：$($Link.description)" }) +
        $(if ($kind) { "`n  類型：$kind" } else { "`n  類型：Dropbox 上還沒有內容" }) +
        "`n  這台電腦的位置：$(if ($cur) { $cur } else { '（未設定）' })"
    $c = Select-Menu $info @('指定位置', '這台電腦不使用', '返回')

    if ($c -eq 1) {
        Set-LinkLocation $Ctx $Link $null
        Write-Act "$label：這台電腦不使用"
        Complete-MenuAction
        return
    }
    if ($c -ne 0) { return }

    $path = Read-PathInput "這台電腦的$(if ($kind) { $kind } else { '檔案或資料夾' })路徑（留空返回）"
    if (-not $path) { return }
    # 備份的是檔案、卻指定了資料夾：放進這個資料夾，檔名沿用原本的
    if ($kind -eq '檔案' -and (Test-Path -LiteralPath $path -PathType Container)) {
        $default = if ($Link.fileName) { $Link.fileName } else { $Link.name }
        $file = "$(Read-Host "要放在這個資料夾裡的檔名（留空使用「$default」）")".Trim()
        $path = Join-Path $path $(if ($file) { $file } else { $default })
    }
    $same = Find-LinkByPath $Ctx $path
    if ($same -and $same.name -ne $Link.name) {
        Write-Warn "$path 已經是「$(Get-LinkLabel $same)」的位置"
        Complete-MenuAction
        return
    }
    Assert-LinkType $Ctx $Link $path
    Set-LinkLocation $Ctx $Link $path
    Write-Act "$label：這台電腦的位置設為 $path"
    Sync-Links $Ctx -Only $Link.name -Interactive
    Complete-MenuAction
}
