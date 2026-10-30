# Documents：把「文件」資料夾的位置指向 Dropbox

$script:ShellFoldersKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

function Get-DocumentsPath { Expand-PathVars (Get-ItemProperty -LiteralPath $script:ShellFoldersKey).Personal }

function Sync-Documents {
    param($Ctx, [switch]$DryRun)
    $rel = $Ctx.Config.documents
    if (-not $rel) { return }
    Write-Step 'Documents 資料夾'
    $target  = if ([IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $Ctx.Root $rel }
    $current = Get-DocumentsPath
    if (Test-SamePath $current $target) { Write-Ok "Documents → $target"; return }
    if ($DryRun) { Write-Plan "Documents 由 $current 改指向 $target"; return }

    New-Item -ItemType Directory -Force $target | Out-Null
    Set-ItemProperty -LiteralPath $script:ShellFoldersKey -Name Personal -Value $target
    Set-ItemProperty -LiteralPath $script:ShellFoldersKey -Name '{F42EE2D3-909F-4907-8871-4C22FC0BF756}' -Value $target
    Write-Act "Documents 已改指向 $target"

    $steps = @('登出再登入，讓所有程式改用新的 Documents 位置')
    $left = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'desktop.ini' -and -not $_.LinkType })
    if ($left.Count) {
        $steps += "舊位置 $current 還有 $($left.Count) 個項目，確認後搬到新位置，例如："
        $steps += "robocopy `"$current`" `"$target`" /E /MOVE /XJ /XF desktop.ini"
    }
    Add-Todo 'Documents 位置已變更' $steps
}
