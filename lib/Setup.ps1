# 一次性系統設定：開發人員模式、登入排程、PATH

$script:DevModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$script:TaskName   = 'win-sync'

function Test-DevMode {
    (Get-ItemProperty -LiteralPath $script:DevModeKey -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense -eq 1
}

function Enable-DevMode {
    if (-not (Test-Path -LiteralPath $script:DevModeKey)) { New-Item -Path $script:DevModeKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $script:DevModeKey -Name AllowDevelopmentWithoutDevLicense -Value 1 -PropertyType DWord -Force | Out-Null
}

function Get-TaskArguments { "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:Entry`" sync -Background" }

function Test-SyncTask {
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    $t -and (@($t.Actions)[0].Arguments -eq (Get-TaskArguments))
}

function Register-SyncTask {
    $user      = "$env:USERDOMAIN\$env:USERNAME"
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-TaskArguments)
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT2M'   # 先讓 Dropbox 同步一下
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description 'win-sync：登入時同步 Dropbox 上的 Windows 設定' -Force | Out-Null
}

function Add-ToUserPath {
    $dir = $script:RepoRoot
    $key = Get-Item -LiteralPath 'HKCU:\Environment'
    $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $parts = @($raw -split ';' | Where-Object { $_ })
    if ($parts | Where-Object { Test-SamePath $_ $dir }) { Write-Ok "PATH 已包含 $dir"; return }
    Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name Path -Value (($parts + $dir) -join ';') -Type ExpandString
    Write-Act "已把 $dir 加入 PATH"
    Add-Todo '重新開啟終端機後，就能在任何位置直接輸入 win-sync' @('若仍找不到指令，登出再登入一次')
}

function Test-Setup {
    Write-Step '系統設定'
    if (Test-DevMode) { Write-Ok '開發人員模式（允許建立檔案連結）' }
    else {
        Write-Warn '開發人員模式未開啟'
        Add-Todo '開發人員模式未開啟，檔案連結可能失敗' @('執行：win-sync init（會要求系統管理員權限）')
    }
    if (Test-SyncTask) { Write-Ok '登入時自動同步' }
    else {
        Write-Warn '尚未設定登入時自動同步（或 win-sync 的位置變了）'
        Add-Todo '尚未設定登入時自動同步' @('執行：win-sync init（會要求系統管理員權限）')
    }
}
