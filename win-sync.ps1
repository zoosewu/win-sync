<#
.SYNOPSIS
  win-sync：透過 Dropbox 同步 Windows 設定、App 設定檔、Documents 與軟體清單。
  執行 win-sync help 查看所有指令。
#>
param(
    [Parameter(Position = 0)][string]$Command = 'menu',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Arguments = @(),
    [switch]$Background,   # 由登入排程呼叫：不輸出到畫面，有待辦時改發 Windows 通知
    [switch]$PauseAtEnd    # 自我提升權限開出的新視窗用：結束前停住讓使用者看結果
)
$ErrorActionPreference = 'Stop'
$script:Entry    = $PSCommandPath
$script:RepoRoot = $PSScriptRoot
foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot 'lib') -Filter *.ps1) { . $f.FullName }
$script:Background = $Background.IsPresent

try {
    switch ($Command.ToLower()) {
        'menu'        { Invoke-Menu }
        'init'        { Invoke-Init }
        'sync'        { Invoke-Sync }
        'status'      { Invoke-Status }
        'add'         { Invoke-Add $Arguments }
        'add-reg'     { Invoke-AddReg $Arguments }
        'apps'        { Invoke-Apps }
        'export-apps' { Invoke-ExportApps }
        default       { Show-Help }
    }
} catch {
    Write-Log "ERROR $($_ | Out-String)"
    Add-Todo "執行時發生錯誤：$($_.Exception.Message)" @(
        "發生位置：$($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)",
        "完整紀錄：$script:LogFile")
}
if (-not $script:NoSummary) { Show-Todos }
if ($PauseAtEnd) { Read-Host "`n按 Enter 關閉視窗" | Out-Null }
