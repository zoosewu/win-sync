# Dropbox：找安裝位置、檢查衝突複本與「僅限線上」檔案

function Test-DropboxInstalled {
    $candidates = @(
        "$env:ProgramFiles\Dropbox\Client\Dropbox.exe",
        "${env:ProgramFiles(x86)}\Dropbox\Client\Dropbox.exe",
        "$env:LOCALAPPDATA\Dropbox\Client\Dropbox.exe")
    foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $true } }
    $false
}

function Get-DropboxRoot {
    foreach ($info in @("$env:LOCALAPPDATA\Dropbox\info.json", "$env:APPDATA\Dropbox\info.json")) {
        if (-not (Test-Path -LiteralPath $info)) { continue }
        $j = Read-Json $info
        foreach ($k in 'personal', 'business') {
            if ($j.$k -and $j.$k.path -and (Test-Path -LiteralPath $j.$k.path)) { return $j.$k.path }
        }
    }
    if (Test-DropboxInstalled) {
        Add-Todo 'Dropbox 尚未登入' @('從開始功能表開啟 Dropbox 並登入帳號', '登入後重新執行此指令')
    } else {
        Add-Todo '尚未安裝 Dropbox' @('執行 win-sync init，它會詢問是否代為安裝', '或手動執行：winget install -e --id Dropbox.Dropbox')
    }
    $null
}

function Test-DropboxFiles($Ctx) {
    Write-Step 'Dropbox 狀態'
    $all = @(Get-ChildItem -LiteralPath $Ctx.Data -Recurse -Force -ErrorAction SilentlyContinue)

    $conflicts = @($all | Where-Object { $_.Name -match 'conflicted copy|衝突' })
    foreach ($c in $conflicts) {
        Write-Warn "衝突複本：$($c.Name)"
        Add-Todo "Dropbox 衝突複本：$($c.Name)" @(
            "位置：$($c.FullName)",
            '代表兩台電腦同時改了同一份設定；比對後把要的內容合併進正本，再刪除這份複本',
            '之後盡量避免兩台電腦同時開著同一個 App')
    }

    # 0x400000 = RECALL_ON_DATA_ACCESS、0x1000 = OFFLINE：雲端預留位置，尚未下載
    $online = @($all | Where-Object { ([int]$_.Attributes -band 0x401000) -ne 0 })
    if ($online.Count) {
        Write-Warn "$($online.Count) 個檔案是「僅限線上」"
        Add-Todo "WinSync 有 $($online.Count) 個檔案是「僅限線上」" @(
            "在檔案總管對 $($Ctx.Data) 按右鍵 →「設為可離線存取」（Make available offline）",
            '否則離線時 App 可能讀不到設定')
    }
    if (-not $conflicts.Count -and -not $online.Count) { Write-Ok '沒有衝突複本，檔案皆可離線使用' }
}
