#Requires -Version 5.1
<#
  sql-server-mcp -- hosts-file test (needs Administrator).

  Covers the piece the offline lifecycle test cannot: the real write into
  C:\Windows\System32\drivers\etc\hosts and its removal. The hosts file is backed
  up first and restored afterwards, and the whole test runs against a scratch
  install root with -SkipPath, so nothing else on the machine changes.

  Examples:
    powershell -ExecutionPolicy Bypass -File .\scripts\test-hosts-admin.ps1
#>
[CmdletBinding()]
param(
  [string]$TestRoot = (Join-Path $env:TEMP ("ssmcp-hosts-" + (Get-Date -Format 'HHmmss'))),
  [string]$LocalAddress = "sql-server-mcp-hosts-test.local"
)

$ErrorActionPreference = 'Stop'
$script:Installer  = Join-Path $PSScriptRoot 'installer-win-x64.ps1'
$script:Remover    = Join-Path $PSScriptRoot 'Remove-win-x64.ps1'
$script:HostsFile  = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$script:Backup     = Join-Path $TestRoot 'hosts.backup'
$script:Settings   = Join-Path $TestRoot 'Settings.json'
$script:Checks     = New-Object System.Collections.Generic.List[object]

function Assert-Check {
  param([string]$Name, [bool]$Condition, [string]$Detail = "")
  [void]$script:Checks.Add([pscustomobject]@{ Name = $Name; Passed = $Condition; Detail = $Detail })
  if ($Condition) { Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green }
  else { Write-Host ("FAIL  {0} {1}" -f $Name, $Detail) -ForegroundColor Red }
}

function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-HostsEntry {
  param([string]$Address)
  foreach ($line in Get-Content -LiteralPath $script:HostsFile) {
    $match = [regex]::Match($line, '^\s*127\.0\.0\.1\s+(?<name>\S+)\s*$')
    if ($match.Success -and $match.Groups['name'].Value -ieq $Address) { return $true }
  }
  return $false
}

function Test-HostsComment {
  param([string]$Address)
  foreach ($line in Get-Content -LiteralPath $script:HostsFile) {
    if ([regex]::IsMatch($line, ('^#\s+sql-server-mcp\s+' + [regex]::Escape($Address) + '\s*$'))) { return $true }
  }
  return $false
}

if (-not (Test-Admin)) {
  Write-Host "This script must run from an elevated prompt (it edits the hosts file)." -ForegroundColor Red
  exit 1
}

New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
Copy-Item -LiteralPath $script:HostsFile -Destination $script:Backup -Force
Write-Host ("hosts backed up to {0}" -f $script:Backup) -ForegroundColor Gray

$started = (Get-Content -LiteralPath $script:HostsFile).Count
Assert-Check "hosts starts without $LocalAddress" (-not (Test-HostsEntry $LocalAddress))

try {
  Write-Host "-> installer -LocalAddress $LocalAddress -SkipPath" -ForegroundColor Yellow
  & $script:Installer -InstallRoot $TestRoot -SettingsPath $script:Settings -LocalAddress $LocalAddress -SkipPath:$true | Out-String -Stream |
    ForEach-Object { if ($_ -ne '') { Write-Host ("   {0}" -f $_) -ForegroundColor DarkGray } }
  Assert-Check "installer exit code is 0" ($LASTEXITCODE -eq 0) "(exit $LASTEXITCODE)"
  Assert-Check "hosts now maps 127.0.0.1 to $LocalAddress" (Test-HostsEntry $LocalAddress)
  Assert-Check "hosts carries the managed marker comment" (Test-HostsComment $LocalAddress)
  Assert-Check "hosts grew by exactly 2 lines" ((Get-Content -LiteralPath $script:HostsFile).Count -eq $started + 2) `
    "(before $started, now $((Get-Content -LiteralPath $script:HostsFile).Count))"

  Write-Host "-> installer again (idempotency)" -ForegroundColor Yellow
  & $script:Installer -InstallRoot $TestRoot -SettingsPath $script:Settings -LocalAddress $LocalAddress -SkipPath:$true -SkipBuild:$true -Quiet:$true
  Assert-Check "second hosts install exits 0" ($LASTEXITCODE -eq 0) "(exit $LASTEXITCODE)"
  Assert-Check "no duplicate hosts line was appended" ((Get-Content -LiteralPath $script:HostsFile).Count -eq $started + 2) `
    "(now $((Get-Content -LiteralPath $script:HostsFile).Count))"

  Write-Host "-> Remove-win-x64.ps1 -LocalAddress $LocalAddress" -ForegroundColor Yellow
  & $script:Remover -InstallRoot $TestRoot -LocalAddress $LocalAddress -Quiet:$true
  Assert-Check "uninstaller exit code is 0" ($LASTEXITCODE -eq 0) "(exit $LASTEXITCODE)"
  Assert-Check "hosts entry removed" (-not (Test-HostsEntry $LocalAddress))
  Assert-Check "hosts marker comment removed" (-not (Test-HostsComment $LocalAddress))
  Assert-Check "hosts is byte-identical to the backup" (
    (Get-FileHash -LiteralPath $script:HostsFile -Algorithm SHA256).Hash -eq
    (Get-FileHash -LiteralPath $script:Backup -Algorithm SHA256).Hash)
} finally {
  Copy-Item -LiteralPath $script:Backup -Destination $script:HostsFile -Force
  Write-Host "hosts restored from backup." -ForegroundColor Gray
  if (Test-Path $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($script:Checks | Where-Object { -not $_.Passed })
Write-Host ""
Write-Host ("Checks: {0}   Passed: {1}   Failed: {2}" -f $script:Checks.Count, ($script:Checks.Count - $failed.Count), $failed.Count) -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
if ($failed.Count -eq 0) { Write-Host "Hosts test passed." -ForegroundColor Green; exit 0 }
$failed | ForEach-Object { Write-Host ("FAILED  {0} {1}" -f $_.Name, $_.Detail) -ForegroundColor Red }
Write-Host "Hosts test failed." -ForegroundColor Red
exit 1
