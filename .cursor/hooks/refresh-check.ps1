# refresh-check.ps1 - Cursor `stop` hook (backstop for the refresh-after-changes skill)
# Author: Armin Dashti | v1.0.0 | 2026-10-17
# If the repo has non-doc changes (working tree, or new commits since last stop) that were not
# already flagged, ask the agent (followup_message) to run .cursor/skills/refresh-after-changes.
# Fails open: any error -> {}. State lives in %TEMP%\cursor-refresh-check (nothing written in repo).
$ErrorActionPreference = 'Stop'
function Out-Json($o) { [Console]::Out.Write(($o | ConvertTo-Json -Compress)); exit 0 }
try {
    $raw = [Console]::In.ReadToEnd()
    $in = $null; if ($raw) { $in = $raw | ConvertFrom-Json }
    if ($in -and $in.status -and $in.status -ne 'completed') { Out-Json @{} }
    if ($in -and $in.loop_count -and [int]$in.loop_count -ge 3) { Out-Json @{} }

    $root = $env:CURSOR_PROJECT_DIR
    if (-not $root -and $in -and $in.workspace_roots) { $root = @($in.workspace_roots)[0] }
    if (-not $root) { $root = (Get-Location).Path }
    Set-Location -LiteralPath $root
    $top = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $top) { Out-Json @{} }
    Set-Location -LiteralPath $top

    $ex = @('*.md','*.mdx','*.log','*.bak','LICENSE*','.cursorrules','docs/**','logs/**','.cursor/**',
            '.agents/**','.armin/**','.claude/**','.codegraph/**','.gitnexus/**','.token-optimizer/**',
            '.zcode/**','.kiro/**','graphify-out/**')
    $spec = @('--', '.') + ($ex | ForEach-Object { ":(exclude,glob)**/$_" }) + ($ex | ForEach-Object { ":(exclude,glob)$_" })

    $status = @(& git -c core.quotepath=off status --porcelain=v1 -uall @spec 2>$null)
    $diff   = (& git -c core.quotepath=off diff HEAD @spec 2>$null) -join "`n"
    $untr   = $status | Where-Object { $_ -like '?? *' } | Select-Object -First 200 | ForEach-Object {
                  $p = $_.Substring(3).Trim('"'); (& git hash-object -- $p 2>$null) }
    $head   = (& git rev-parse HEAD 2>$null)

    $stateDir = Join-Path $env:TEMP 'cursor-refresh-check'
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $sha = [Security.Cryptography.SHA1]::Create()
    $key = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($top.ToLower())) | ForEach-Object { $_.ToString('x2') })
    $stateFile = Join-Path $stateDir "$key.json"
    $state = $null; if (Test-Path $stateFile) { $state = Get-Content -Raw $stateFile | ConvertFrom-Json }

    $committed = @()
    if ($state -and $state.head -and $head -and $state.head -ne $head) {
        $committed = @(& git diff --name-only $state.head $head @spec 2>$null)
    }
    $work = ($status.Count -gt 0)
    $fp = ''
    if ($work -or $committed.Count -gt 0) {
        $blob = ($status -join "`n") + "`n#" + $diff + "`n#" + ($untr -join ',') + "`n#" + ($committed -join ',')
        $fp = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($blob)) | ForEach-Object { $_.ToString('x2') })
    }
    $prev = ''; if ($state -and $state.fp) { $prev = $state.fp }
    @{ fp = $(if ($fp) { $fp } else { $prev }); head = $head; repo = $top; at = (Get-Date -Format s) } |
        ConvertTo-Json -Compress | Set-Content -Encoding ASCII $stateFile

    if (-not $fp -or $fp -eq $prev) { Out-Json @{} }

    $files = @($status | ForEach-Object { $_.Substring(3) }) + $committed | Select-Object -Unique -First 15
    $msg = "Refresh check (stop hook): this task changed non-doc files (" + ($files -join ', ') + "). " +
           "Before finishing, read and follow .cursor/skills/refresh-after-changes/SKILL.md: rebuild/restart/redeploy-local " +
           "the affected app(s) the way that skill and this repo's rules specify, verify the change is live, then report what " +
           "was refreshed and how. If it was already refreshed and verified in this task, or the changes are non-executable, " +
           "reply with one line saying so and do nothing else."
    Out-Json @{ followup_message = $msg }
} catch { [Console]::Out.Write('{}'); exit 0 }
