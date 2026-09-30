#Requires -Version 5.1
<#
  sql-server-mcp -- Windows x64 lifecycle test.

  Exercises build -> install -> update -> remove and asserts the real effects on
  disk, on the user PATH and in the hosts file. Nothing is faked: the installer
  and uninstaller run for real against a scratch install root, which is deleted
  again at the end.

  Examples:
    powershell -ExecutionPolicy Bypass -File .\scripts\test-win-x64.ps1
    powershell -ExecutionPolicy Bypass -File .\scripts\test-win-x64.ps1 -SkipHosts
#>
[CmdletBinding()]
param(
  [string]$TestRoot = (Join-Path $env:TEMP ("ssmcp-lifecycle-" + (Get-Date -Format 'HHmmss'))),
  [string]$LocalAddress = "sql-server-mcp-test.local",
  [switch]$KeepArtifacts,
  [switch]$SkipHosts
)

$ErrorActionPreference = 'Stop'
$script:ProjectRoot  = Split-Path -Parent $PSScriptRoot
$script:Installer    = Join-Path $PSScriptRoot 'installer-win-x64.ps1'
$script:Remover      = Join-Path $PSScriptRoot 'Remove-win-x64.ps1'
$script:ExeName      = "sql-server-mcp.exe"
$script:PublishExe   = Join-Path $script:ProjectRoot "dist\$script:ExeName"
$script:Settings     = Join-Path $TestRoot 'Settings.json'
$script:TargetExe    = Join-Path $TestRoot $script:ExeName
$script:HostsFile    = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$script:RootMarker   = $TestRoot.TrimEnd('\')
$script:Checks       = New-Object System.Collections.Generic.List[object]
$script:OriginalPath = [Environment]::GetEnvironmentVariable('Path', 'User')

function Write-Head {
  param([string]$Message)
  Write-Host ""
  Write-Host ("=== {0}" -f $Message) -ForegroundColor Cyan
}

function Write-Step {
  param([string]$Message)
  Write-Host ("-> {0}" -f $Message) -ForegroundColor Yellow
}

function Assert-Check {
  param([string]$Name, [bool]$Condition, [string]$Detail = "")
  [void]$script:Checks.Add([pscustomobject]@{ Name = $Name; Passed = $Condition; Detail = $Detail })
  if ($Condition) {
    Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green
  } else {
    Write-Host ("FAIL  {0} {1}" -f $Name, $Detail) -ForegroundColor Red
  }
}

function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UserPathEntries {
  $value = [Environment]::GetEnvironmentVariable('Path', 'User')
  return @($value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-PathEntryCount {
  return @(Get-UserPathEntries | Where-Object { $_.TrimEnd('\') -ieq $script:RootMarker }).Count
}

function Test-HostsEntry {
  param([string]$Address)
  if (-not (Test-Path $script:HostsFile)) { return $false }
  foreach ($line in Get-Content -LiteralPath $script:HostsFile) {
    $match = [regex]::Match($line, '^\s*127\.0\.0\.1\s+(?<name>\S+)\s*$')
    if ($match.Success -and $match.Groups['name'].Value -ieq $Address) { return $true }
  }
  return $false
}

function Invoke-Script {
  param([string]$Path, [hashtable]$Parameters)
  $rendered = ($Parameters.GetEnumerator() | ForEach-Object { "-{0} {1}" -f $_.Key, $_.Value }) -join ' '
  Write-Step ("{0} {1}" -f (Split-Path -Leaf $Path), $rendered)
  & $Path @Parameters | Out-String -Stream | ForEach-Object { if ($_ -ne '') { Write-Host ("   {0}" -f $_) -ForegroundColor DarkGray } }
  return $LASTEXITCODE
}

function Get-McpToolCount {
  param([string]$ExePath)
  Write-Step ("MCP stdio handshake against {0}" -f (Split-Path -Leaf $ExePath))
  $requests = @(
    @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'lifecycle-test'; version = '1.0.0' } } },
    @{ jsonrpc = '2.0'; method = 'notifications/initialized' },
    @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} }
  )
  $payload = (($requests | ForEach-Object { $_ | ConvertTo-Json -Depth 6 -Compress }) -join "`n") + "`n"
  $output = $payload | & $ExePath
  if ($LASTEXITCODE -ne 0) { return $null }
  $line = @($output | Where-Object { $_ -match '"id"\s*:\s*2' }) | Select-Object -First 1
  if (-not $line) { return $null }
  try { return @(($line | ConvertFrom-Json).result.tools).Count } catch { return $null }
}

Write-Host "sql-server-mcp lifecycle test" -ForegroundColor Cyan
Write-Host ("Project    : {0}" -f $script:ProjectRoot) -ForegroundColor Gray
Write-Host ("Scratch    : {0}" -f $TestRoot) -ForegroundColor Gray
Write-Host ("Local name : {0}" -f $LocalAddress) -ForegroundColor Gray
Write-Host ("User PATH  : {0} entries (restored at the end)" -f (Get-UserPathEntries).Count) -ForegroundColor Gray
$isAdmin = Test-Admin
$hostsEnabled = (-not $SkipHosts) -and $isAdmin
Write-Host ("Elevated   : {0}   hosts assertions: {1}" -f $isAdmin, $hostsEnabled) -ForegroundColor Gray

if (-not (Test-Path $script:Installer)) { Write-Host "installer-win-x64.ps1 not found next to this script." -ForegroundColor Red; exit 1 }
if (-not (Test-Path $script:Remover)) { Write-Host "Remove-win-x64.ps1 not found next to this script." -ForegroundColor Red; exit 1 }
if (Test-Path $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }

Write-Head "Phase 0 - baseline"
Assert-Check "Scratch install root starts absent" (-not (Test-Path $TestRoot))
Assert-Check "User PATH starts free of the scratch root" ((Get-PathEntryCount) -eq 0)

Write-Head "Phase 1 - build"
$before = if (Test-Path $script:PublishExe) { (Get-Item $script:PublishExe).LastWriteTimeUtc } else { [datetime]::MinValue }
$code = Invoke-Script $script:Installer @{
  InstallRoot  = $TestRoot
  SettingsPath = $script:Settings
  SkipPath     = $true
  Quiet        = $true
}
Assert-Check "Installer exit code is 0" ($code -eq 0) "(exit $code)"
Assert-Check "dist\$script:ExeName exists" (Test-Path $script:PublishExe)
Assert-Check "executable was rebuilt in this run" ((Test-Path $script:PublishExe) -and (Get-Item $script:PublishExe).LastWriteTimeUtc -gt $before)
Assert-Check "executable size is plausible" ((Test-Path $script:PublishExe) -and (Get-Item $script:PublishExe).Length -gt 10MB)
Assert-Check "install root created" (Test-Path $TestRoot)
Assert-Check "installed executable copied into the install root" (Test-Path $script:TargetExe)
Assert-Check "Settings.json seeded" (Test-Path $script:Settings)
Assert-Check "Data.db created" (Test-Path (Join-Path $TestRoot 'Data.db'))
Assert-Check "PATH untouched while -SkipPath was used" ((Get-PathEntryCount) -eq 0)
$installedExe = Invoke-Script $script:Installer @{
  InstallRoot  = $TestRoot
  SettingsPath = $script:Settings
  SkipBuild    = $true
}
Assert-Check "re-install over the installed file exits 0" ($installedExe -eq 0) "(exit $installedExe)"
Assert-Check "existing settings preserved on re-install" (Test-Path $script:Settings)
$toolCount = Get-McpToolCount $script:TargetExe
Assert-Check "installed executable completes an MCP handshake" ($null -ne $toolCount)
Assert-Check "tools/list returns the 9 registered tools" ($toolCount -eq 9) "(got $toolCount)"

Write-Head "Phase 2 - update"
$beforeUpdate = (Get-Item $script:TargetExe).LastWriteTimeUtc
Start-Sleep -Seconds 1
$code = Invoke-Script $script:Installer @{
  InstallRoot  = $TestRoot
  SettingsPath = $script:Settings
  Quiet        = $true
}
Assert-Check "Update run exit code is 0" ($code -eq 0) "(exit $code)"
Assert-Check "previous executable replaced" ((Get-Item $script:TargetExe).LastWriteTimeUtc -gt $beforeUpdate)
Assert-Check "Settings.json survived the update" (Test-Path $script:Settings)
Assert-Check "Data.db survived the update" (Test-Path (Join-Path $TestRoot 'Data.db'))
Assert-Check "install root registered on the user PATH" ((Get-PathEntryCount) -eq 1)
Assert-Check "executable is resolvable by name via PATH" ($null -ne (Get-Command $script:ExeName -ErrorAction SilentlyContinue))
$code = Invoke-Script $script:Installer @{
  InstallRoot  = $TestRoot
  SettingsPath = $script:Settings
  Quiet        = $true
}
Assert-Check "repeat install exit code is 0" ($code -eq 0) "(exit $code)"
Assert-Check "PATH entry is not duplicated" ((Get-PathEntryCount) -eq 1)
$toolCount = Get-McpToolCount $script:TargetExe
Assert-Check "updated executable still answers tools/list" ($toolCount -eq 9) "(got $toolCount)"

Write-Head "Phase 3 - hosts file mapping"
if ($hostsEnabled) {
  $code = Invoke-Script $script:Installer @{
    InstallRoot    = $TestRoot
    SettingsPath   = $script:Settings
    LocalAddress   = $LocalAddress
    AllowElevation = $false
    Quiet          = $true
  }
  Assert-Check "install with -LocalAddress exit code is 0" ($code -eq 0) "(exit $code)"
  Assert-Check "hosts maps 127.0.0.1 to $LocalAddress" (Test-HostsEntry $LocalAddress)
  Assert-Check "PATH entry still single after hosts install" ((Get-PathEntryCount) -eq 1)
} else {
  Write-Host "SKIP  hosts assertions - re-run from an elevated prompt to cover them" -ForegroundColor Yellow
}

Write-Head "Phase 4 - remove"
$code = Invoke-Script $script:Remover @{
  InstallRoot    = $TestRoot
  LocalAddress   = $LocalAddress
  AllowElevation = $false
  Quiet          = $true
}
Assert-Check "Uninstaller exit code is 0" ($code -eq 0) "(exit $code)"
Assert-Check "installed executable deleted" (-not (Test-Path $script:TargetExe))
Assert-Check "install root deleted with all contents" (-not (Test-Path $TestRoot))
Assert-Check "user PATH entry removed" ((Get-PathEntryCount) -eq 0)
if ([Environment]::GetEnvironmentVariable('SQL_SERVER_CONFIG', 'User')) {
  Assert-Check "SQL_SERVER_CONFIG user variable cleared" $false "still set to $([Environment]::GetEnvironmentVariable('SQL_SERVER_CONFIG', 'User'))"
} else {
  Assert-Check "SQL_SERVER_CONFIG user variable cleared" $true
}
if ($hostsEnabled) {
  Assert-Check "hosts entry for $LocalAddress removed" (-not (Test-HostsEntry $LocalAddress))
} else {
  Write-Host "SKIP  hosts cleanup assertion - needs elevation" -ForegroundColor Yellow
}
$code = Invoke-Script $script:Remover @{
  InstallRoot    = $TestRoot
  AllowElevation = $false
  Quiet          = $true
}
Assert-Check "idempotent uninstall exits 0" ($code -eq 0) "(exit $code)"

Write-Head "Phase 5 - restore"
[Environment]::SetEnvironmentVariable('Path', $script:OriginalPath, 'User')
Assert-Check "original user PATH restored" ([Environment]::GetEnvironmentVariable('Path', 'User') -eq $script:OriginalPath)
if (-not $KeepArtifacts) {
  if (Test-Path $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
  Write-Host "Scratch artifacts removed." -ForegroundColor Gray
} else {
  Write-Host ("Scratch artifacts kept at {0}" -f $TestRoot) -ForegroundColor Yellow
}

$failed = @($script:Checks | Where-Object { -not $_.Passed })
Write-Head "Summary"
Write-Host ("Checks: {0}   Passed: {1}   Failed: {2}" -f $script:Checks.Count, ($script:Checks.Count - $failed.Count), $failed.Count) -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
foreach ($failure in $failed) {
  Write-Host ("FAILED  {0} {1}" -f $failure.Name, $failure.Detail) -ForegroundColor Red
}
if ($failed.Count -eq 0) {
  Write-Host "Lifecycle test passed." -ForegroundColor Green
  exit 0
}
Write-Host "Lifecycle test failed." -ForegroundColor Red
exit 1
