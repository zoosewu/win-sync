# 軟體清單：apps.json 是 winget export 的格式，可直接用 winget import 安裝

function Test-Winget {
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    Add-Todo 'winget 無法使用' @('從 Microsoft Store 安裝或更新「應用程式安裝程式」（App Installer）', '完成後重新執行此指令')
    $false
}

function Get-WingetIds([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $j = Read-Json $Path
    @(foreach ($s in (Get-List $j 'Sources')) { foreach ($p in (Get-List $s 'Packages')) { $p.PackageIdentifier } })
}

function Export-Installed {
    $tmp = Join-Path $env:TEMP "win-sync-installed-$PID.json"
    winget export -o $tmp --accept-source-agreements --disable-interactivity *> $null
    if (-not (Test-Path -LiteralPath $tmp)) { throw 'winget export 失敗，無法取得已安裝軟體清單' }
    $tmp
}

function Get-MissingApps([string[]]$Want) {
    $tmp = Export-Installed
    try { $have = Get-WingetIds $tmp } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    @($Want | Where-Object { $have -notcontains $_ })
}

function Test-Apps($Ctx) {
    Write-Step '軟體'
    $want = Get-WingetIds (Join-Path $Ctx.Data 'apps.json')
    if (-not $want.Count) { Write-Skip 'apps.json 沒有任何軟體（用 win-sync export-apps 匯出）'; return }
    if (-not (Test-Winget)) { return }
    $missing = Get-MissingApps $want
    if (-not $missing.Count) { Write-Ok "apps.json 的 $($want.Count) 個軟體都已安裝"; return }
    foreach ($m in $missing) { Write-Warn "未安裝：$m" }
    Add-Todo "有 $($missing.Count) 個軟體尚未安裝" @('執行：win-sync apps（安裝程式可能跳出 UAC，請留在電腦前）')
}

function Install-MissingApps {
    param($Ctx, [switch]$Ask)
    Write-Step '安裝軟體'
    $file = Join-Path $Ctx.Data 'apps.json'
    $want = Get-WingetIds $file
    if (-not $want.Count) { Write-Skip 'apps.json 沒有任何軟體'; return }
    if (-not (Test-Winget)) { return }
    $missing = Get-MissingApps $want
    if (-not $missing.Count) { Write-Ok "apps.json 的 $($want.Count) 個軟體都已安裝"; return }
    foreach ($m in $missing) { Write-Warn "未安裝：$m" }
    if ($Ask -and -not (Confirm-Ask "要現在安裝這 $($missing.Count) 個軟體嗎？（安裝程式可能跳出 UAC）")) {
        Add-Todo "有 $($missing.Count) 個軟體尚未安裝" @('之後執行：win-sync apps')
        return
    }
    winget import -i $file --ignore-unavailable --ignore-versions --accept-package-agreements --accept-source-agreements
    $still = Get-MissingApps $want
    if ($still.Count) {
        Add-Todo "有 $($still.Count) 個軟體安裝失敗或找不到來源" (
            @($still | ForEach-Object { "未安裝：$_" }) +
            '可執行 winget install -e --id <ID> 查看原因，或從 apps.json 移除')
    } else {
        Write-Ok '全部安裝完成'
    }
}

# 把這台電腦已安裝的軟體「併入」apps.json（不會刪掉其他電腦加入的項目）
function Export-Apps($Ctx) {
    if (-not (Test-Winget)) { return }
    Write-Step '匯出已安裝軟體到 apps.json'
    $file = Join-Path $Ctx.Data 'apps.json'
    $tmp = Export-Installed
    try {
        if (-not (Get-WingetIds $file).Count) {
            Copy-Item -LiteralPath $tmp -Destination $file -Force
            $added = (Get-WingetIds $file).Count
        } else {
            $cur = Read-Json $file
            $new = Read-Json $tmp
            $added = 0
            foreach ($src in Get-List $new 'Sources') {
                $dst = Get-List $cur 'Sources' | Where-Object { $_.SourceDetails.Name -eq $src.SourceDetails.Name } | Select-Object -First 1
                if (-not $dst) {
                    Set-ConfigList $cur 'Sources' (@(Get-List $cur 'Sources') + $src)
                    $added += @(Get-List $src 'Packages').Count
                    continue
                }
                $ids = @(Get-List $dst 'Packages' | ForEach-Object { $_.PackageIdentifier })
                $add = @(Get-List $src 'Packages' | Where-Object { $ids -notcontains $_.PackageIdentifier })
                if ($add.Count) {
                    Set-ConfigList $dst 'Packages' (@(Get-List $dst 'Packages') + $add)
                    $added += $add.Count
                }
            }
            Write-Json $file $cur
        }
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    Write-Act "apps.json 新增 $added 個軟體"
    if ($added) {
        Add-Todo "apps.json 新增了 $added 個軟體，請檢查一次" @(
            "開啟 $file",
            '移除不想每台電腦都安裝的項目（驅動程式、系統元件、試用軟體等）')
    }
}
