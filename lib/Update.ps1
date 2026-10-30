# 自動更新工具本身：git clone 安裝的用 git 快轉；下載 zip 安裝的重新下載覆蓋（保留 local.json）
# 背景同步時一天最多檢查一次；local.json 設 "autoUpdate": false 可關閉

$script:RepoSlug        = 'zoosewu/win-sync'
$script:Branch          = 'main'
$script:VersionFile     = '.win-sync-version'   # zip 安裝時記錄目前的 commit
$script:LastUpdateCheck = Join-Path $script:StateDir 'last-update-check.txt'

function Test-AutoUpdateEnabled {
    $s = Read-LocalState
    -not ($s.PSObject.Properties['autoUpdate'] -and $s.autoUpdate -eq $false)
}

# 背景同步用：失敗只寫紀錄，不產生待辦（例如剛登入還沒有網路）
function Invoke-AutoUpdate {
    if (-not (Test-AutoUpdateEnabled)) { return }
    if ((Test-Path -LiteralPath $script:LastUpdateCheck) -and
        (Get-Item -LiteralPath $script:LastUpdateCheck).LastWriteTime -gt (Get-Date).AddHours(-20)) { return }
    try {
        Update-Self
        if (-not (Test-Path -LiteralPath $script:StateDir)) { New-Item -ItemType Directory -Force $script:StateDir | Out-Null }
        Set-Content -LiteralPath $script:LastUpdateCheck (Get-Date -Format s)
    } catch {
        Write-Log "自動更新失敗：$($_.Exception.Message)"
    }
}

function Update-Self {
    Write-Step '更新 win-sync'
    $root = $script:RepoRoot
    if (Test-Path -LiteralPath (Join-Path $root '.git')) { Update-ByGit $root } else { Update-ByZip $root }
}

function Update-ByGit([string]$Root) {
    # 5.1 在 Stop 模式下，git 寫到 stderr 的訊息會變成例外，這裡改看 $LASTEXITCODE
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw '找不到 git，無法更新（安裝：winget install -e --id Git.Git）' }
    $branch = git -C $Root rev-parse --abbrev-ref HEAD 2>$null
    if ($branch -ne $script:Branch) { Write-Skip "目前在 $branch 分支，不自動更新（只更新 $script:Branch）"; return }
    if (git -C $Root status --porcelain 2>$null) { Write-Skip '工具資料夾有未提交的修改，不自動更新'; return }
    git -C $Root fetch --quiet origin $script:Branch 2>&1 | Out-Null
    if ($LASTEXITCODE) { throw '無法從 GitHub 取得更新（git fetch 失敗）' }
    $behind = [int](git -C $Root rev-list --count "HEAD..origin/$script:Branch")
    $ahead  = [int](git -C $Root rev-list --count "origin/$script:Branch..HEAD")
    if (-not $behind) { Write-Ok "已是最新版（$(git -C $Root rev-parse --short HEAD)）"; return }
    if ($ahead) { Write-Skip "本機有 $ahead 個尚未推送的 commit，不自動更新"; return }
    git -C $Root merge --ff-only --quiet "origin/$script:Branch" 2>&1 | Out-Null
    if ($LASTEXITCODE) { throw '更新失敗（git merge --ff-only）' }
    Write-Act "已更新 $behind 個版本（$(git -C $Root rev-parse --short HEAD)），下次執行時生效"
}

function Update-ByZip([string]$Root) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $latest = (Invoke-RestMethod "https://api.github.com/repos/$script:RepoSlug/commits/$script:Branch" `
        -UseBasicParsing -Headers @{ 'User-Agent' = 'win-sync' }).sha
    if (-not $latest) { throw '無法從 GitHub 取得最新版本資訊' }
    $verFile = Join-Path $Root $script:VersionFile
    $current = if (Test-Path -LiteralPath $verFile) { "$(Get-Content -LiteralPath $verFile -Raw)".Trim() } else { '' }
    if ($current -eq $latest) { Write-Ok "已是最新版（$($latest.Substring(0, 7))）"; return }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "win-sync-update-$PID"
    try {
        New-Item -ItemType Directory -Force $tmp | Out-Null
        $zip = Join-Path $tmp 'src.zip'
        Invoke-WebRequest "https://github.com/$script:RepoSlug/archive/$latest.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp
        $src = @(Get-ChildItem -LiteralPath $tmp -Directory)[0].FullName
        if (-not (Test-Path -LiteralPath (Join-Path $src 'win-sync.ps1'))) { throw '下載的內容不完整' }
        # 不用 /MIR：工具資料夾裡若有使用者自己的檔案，不能被刪掉
        robocopy $src $Root /E /XF local.json $script:VersionFile /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "複製檔案失敗（robocopy 代碼 $LASTEXITCODE）" }
        # lib 底下的 .ps1 都會被載入，上游刪掉的要一併刪除
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Filter *.ps1) {
            if (-not (Test-Path -LiteralPath (Join-Path $src "lib\$($f.Name)"))) { Remove-Item -LiteralPath $f.FullName }
        }
        Set-Content -LiteralPath $verFile $latest
        Write-Act "已更新到 $($latest.Substring(0, 7))，下次執行時生效"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
