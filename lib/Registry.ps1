# Windows 設定：config.json 的 registry 清單是宣告式的，每次同步都把這些值套用到本機

# 接受登錄編輯程式網址列複製的格式（電腦\HKEY_CURRENT_USER\...）
function ConvertTo-PSRegKey([string]$Key) {
    $k = $Key.Trim() -replace '^(Computer|電腦)\\', ''
    $k = $k -replace '^HKEY_CURRENT_USER', 'HKCU:' -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
    $k -replace '^(HKCU|HKLM)\\', '$1:\'
}

function Get-RegValue([string]$Key, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Key)) { return $null }
    $item = Get-Item -LiteralPath $Key
    if ($item.GetValueNames() -notcontains $Name) { return $null }
    [pscustomobject]@{
        Value = $item.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Type  = $item.GetValueKind($Name).ToString()
    }
}

function Format-RegValue($Value) {
    if ($Value -is [array]) { return (@($Value) | ForEach-Object { "$_" }) -join ',' }
    "$Value"
}

function ConvertTo-RegData($Value, [string]$Type) {
    switch ($Type) {
        'Binary'      { return ,([byte[]]@($Value)) }
        'MultiString' { return ,([string[]]@($Value)) }
        default       { return $Value }
    }
}

function Get-RegLabel($Entry) {
    if ($Entry.label) { return $Entry.label }
    "$($Entry.key)\$($Entry.name)"
}

function Sync-Registry {
    param($Ctx, [switch]$DryRun)
    Write-Step 'Windows 設定（registry）'
    $entries = @(Get-List $Ctx.Config 'registry')
    if (-not $entries.Count) { Write-Skip '尚未設定任何項目（用 win-sync add-reg <機碼> <值名稱> 新增）'; return }
    $changed = 0
    foreach ($r in $entries) {
        $label = Get-RegLabel $r
        try {
            $cur  = Get-RegValue $r.key $r.name
            $want = Format-RegValue $r.value
            if ($cur -and (Format-RegValue $cur.Value) -eq $want) { Write-Ok $label; continue }
            $from = if ($cur) { Format-RegValue $cur.Value } else { '（無）' }
            if ($DryRun) { Write-Plan "$label：$from → $want"; continue }
            if (-not (Test-Path -LiteralPath $r.key)) { New-Item -Path $r.key -Force | Out-Null }
            New-ItemProperty -LiteralPath $r.key -Name $r.name -Value (ConvertTo-RegData $r.value $r.type) `
                -PropertyType $r.type -Force | Out-Null
            Write-Act "$label：$from → $want"
            $changed++
        } catch {
            Write-Warn "$label：$($_.Exception.Message)"
            Add-Todo "Windows 設定「$label」套用失敗" @(
                $_.Exception.Message,
                'HKLM 底下的設定需要系統管理員：以系統管理員開終端機執行 win-sync sync')
        }
    }
    if ($changed) {
        Add-Todo "已變更 $changed 項 Windows 設定" @('部分設定要登出再登入（或重新啟動檔案總管）才會生效')
    }
}

function Invoke-AddReg([string[]]$Arguments) {
    if ($Arguments.Count -lt 2) {
        Write-Host '用法：win-sync add-reg <機碼> <值名稱> [說明]'
        Write-Host '例如：win-sync add-reg "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" HideFileExt "顯示副檔名"'
        $script:NoSummary = $true
        return
    }
    $ctx = Get-Context
    if (-not $ctx) { return }
    $key  = ConvertTo-PSRegKey $Arguments[0]
    $name = $Arguments[1]
    $cur  = Get-RegValue $key $name
    if (-not $cur) { throw "這台電腦找不到登錄值：$key\$name（請先在設定中改一次，讓它產生）" }

    $entry = [pscustomobject]@{ label = $null; key = $key; name = $name; value = $cur.Value; type = $cur.Type }
    if ($Arguments.Count -ge 3) { $entry.label = $Arguments[2] }
    $others = @(Get-List $ctx.Config 'registry' | Where-Object { -not ($_.key -ieq $key -and $_.name -ieq $name) })
    Set-ConfigList $ctx.Config 'registry' ($others + $entry)
    Write-Json $ctx.ConfigPath $ctx.Config
    Write-Act "已記錄 $(Get-RegLabel $entry) = $(Format-RegValue $cur.Value)（$($cur.Type)），其他電腦下次同步時套用"
}
