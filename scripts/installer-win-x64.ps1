#Requires -Version 5.1
<#
  sql-server-mcp -- Windows x64 installer / updater.

  Builds dist\sql-server-mcp.exe (esbuild bundle + Node SEA via @yao-pkg/pkg),
  stops any running instance, installs the executable under
  %LOCALAPPDATA%\SqlServerMcp, seeds Settings.json + Data.db, registers the
  install folder on the user PATH and optionally maps --local-address into the
  Windows hosts file (requires Administrator).

  Examples:
    powershell -ExecutionPolicy Bypass -File .\scripts\installer-win-x64.ps1
    powershell -ExecutionPolicy Bypass -File .\scripts\installer-win-x64.ps1 -LocalAddress sqlserver.local
#>
[CmdletBinding()]
param(
  [string]$LocalAddress = "",
  [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "SqlServerMcp"),
  [string]$SettingsPath = (Join-Path $env:LOCALAPPDATA "SqlServerMcp\Settings.json"),
  [switch]$SkipBuild,
  [switch]$SkipPath,
  [switch]$AllowElevation = $true,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:ProjectRoot  = Split-Path -Parent $PSScriptRoot
$script:AppName      = "sql-server-mcp"
$script:ExeName      = "sql-server-mcp.exe"
$script:PublishExe   = Join-Path ${script:ProjectRoot} "dist\${script:ExeName}"
$script:TargetExe    = Join-Path $InstallRoot ${script:ExeName}
$script:HostsFile    = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$script:PathMarker   = $InstallRoot.TrimEnd('\')
$script:HostsChanged = $false

function Write-Line {
  param([string]$Status, [string]$Message, [string]$Color)
  if ($Quiet) { return }
  Write-Host ("[{0}] {1}" -f $Status, $Message) -ForegroundColor $Color
}

function Write-Info    { param([string]$Message) Write-Line "INFO"    $Message 'Yellow' }
function Write-Ok      { param([string]$Message) Write-Line "SUCCESS" $Message 'Green' }
function Write-Warn    { param([string]$Message) Write-Line "WARN"    $Message 'Yellow' }
function Write-Problem { param([string]$Message) Write-Line "ERROR"   $Message 'Red' }

function Fail {
  param([string]$Message, [int]$Code = 1)
  Write-Problem $Message
  exit $Code
}

function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Split-PathList {
  param([string]$Value)
  return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-Processes {
  return @(Get-Process -Name ${script:AppName} -ErrorAction SilentlyContinue)
}

function Stop-InstalledApp {
  $running = Get-Processes
  if ($running.Count -eq 0) {
    Write-Info "No running ${script:ExeName} process."
    return
  }
  foreach ($process in $running) {
    Write-Info ("Stopping PID {0} ({1})" -f $process.Id, $process.ProcessName)
    $process.CloseMainWindow() | Out-Null
  }
  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Processes).Count -gt 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
  }
  foreach ($process in Get-Processes) {
    try {
      [void]$process.Kill()
      $process.WaitForExit(5000)
    } catch {
      Write-Warn ("Force stop failed for PID {0}: {1}" -f $process.Id, $_.Exception.Message)
    }
  }
  Start-Sleep -Milliseconds 400
  if ((Get-Processes).Count -gt 0) { Fail "Could not stop every ${script:ExeName} process." }
  Write-Ok "Running instance stopped."
}

function Get-NodeMajor {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { return 0 }
  $version = (& $node.Source --version) 2>$null
  if (-not $version) { return 0 }
  return [int](($version -replace '^v', '') -split '\.')[0]
}

function Ensure-Toolchain {
  foreach ($tool in @('node', 'npm')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
      Fail "Required tool '$tool' was not found on PATH."
    }
  }
  $major = Get-NodeMajor
  if ($major -lt 22) {
    Fail ("Node.js 22 or newer is required to build the single executable (found major {0})." -f $major)
  }
  if (-not (Test-Path (Join-Path ${script:ProjectRoot} 'package.json'))) {
    Fail "package.json not found under ${script:ProjectRoot}."
  }
  Write-Info ("Node.js v{0} toolchain ready." -f $major)
}

function Invoke-Step {
  param([string]$Label, [scriptblock]$Command)
  Write-Info $Label
  & $Command | Out-String -Stream | ForEach-Object { if ($_ -ne '') { Write-Verbose $_ } }
  if ($LASTEXITCODE -ne 0) { Fail ("{0} failed with exit code {1}." -f $Label, $LASTEXITCODE) }
}

function Invoke-Build {
  Push-Location ${script:ProjectRoot}
  try {
    $entry = Join-Path ${script:ProjectRoot} 'src\sea-entry.js'
    if (-not (Test-Path $entry)) { Fail "SEA entry point not found: $entry" }
    if (-not (Test-Path (Join-Path ${script:ProjectRoot} 'node_modules'))) {
      Invoke-Step "Installing npm dependencies" { npm install --no-audit --no-fund }
    }
    Invoke-Step "Compiling TypeScript" { npm run build }
    $bundleOut = Join-Path dist 'sea-bundle.cjs'
    $exeOut = Join-Path dist ${script:ExeName}
    $esbuild = Join-Path ${script:ProjectRoot} 'node_modules\.bin\esbuild.cmd'
    $pkg = Join-Path ${script:ProjectRoot} 'node_modules\.bin\pkg.cmd'
    if (Test-Path $esbuild) {
      Invoke-Step "Bundling SEA entry point" {
        & $esbuild $entry --bundle --platform=node --format=cjs --target=node24 --outfile=$bundleOut
      }
    } else {
      Invoke-Step "Bundling SEA entry point (npm exec)" {
        npm exec --yes --package=esbuild@^0.25.0 -- esbuild $entry --bundle --platform=node --format=cjs --target=node24 --outfile=$bundleOut
      }
    }
    if (Test-Path $pkg) {
      Invoke-Step "Packaging Windows x64 executable" {
        & $pkg $bundleOut --targets node24-win-x64 --output $exeOut --sea
      }
    } else {
      Invoke-Step "Packaging Windows x64 executable (npm exec)" {
        npm exec --yes --package=@yao-pkg/pkg@^6.23.0 -- pkg $bundleOut --targets node24-win-x64 --output $exeOut --sea
      }
    }
  } finally {
    Pop-Location
  }
  $bundle = Join-Path ${script:ProjectRoot} 'dist\sea-bundle.cjs'
  if (Test-Path $bundle) { Remove-Item $bundle -Force }
  if (-not (Test-Path ${script:PublishExe})) { Fail "Build produced no executable at ${script:PublishExe}." }
  $size = (Get-Item ${script:PublishExe}).Length
  if ($size -lt 1MB) { Fail "Built executable looks truncated ($size bytes)." }
  Write-Ok ("Executable built: {0} ({1:N1} MB)" -f ${script:PublishExe}, ($size / 1MB))
}

function Test-HostsEntry {
  param([string]$Address)
  if (-not (Test-Path ${script:HostsFile})) { Fail "hosts file not found: $(${script:HostsFile})" }
  foreach ($line in Get-Content -LiteralPath ${script:HostsFile}) {
    $match = [regex]::Match($line, '^\s*127\.0\.0\.1\s+(?<name>\S+)\s*$')
    if ($match.Success -and $match.Groups['name'].Value -ieq $Address) { return $true }
  }
  return $false
}

function Write-HostsEntry {
  param([string]$Address)
  if (-not (Test-Admin)) { Fail "Administrator rights are required to modify $(${script:HostsFile})." }
  $existing = @(Get-Content -LiteralPath ${script:HostsFile})
  $kept = @($existing | Where-Object {
    -not ([regex]::IsMatch($_, ('^\s*127\.0\.0\.1\s+' + [regex]::Escape($Address) + '\s*$')) -or
           [regex]::IsMatch($_, ('^\s*#\s+sql-server-mcp\s+' + [regex]::Escape($Address) + '\s*$')))
  })
  $kept += "127.0.0.1`t$Address"
  $kept += "# sql-server-mcp $Address"
  Set-Content -LiteralPath ${script:HostsFile} -Value $kept -Encoding ASCII
  $script:HostsChanged = $true
  Write-Ok ("hosts entry added: 127.0.0.1 -> {0}" -f $Address)
}

function Invoke-Elevated {
  if (-not $AllowElevation) {
    Fail ("Administrator rights are required for --local-address=$LocalAddress. Re-run from an elevated prompt.")
  }
  $exe = (Get-Process -Id $PID).Path
  $file = $PSCommandPath
  if (-not $file) {
    Fail ("Not elevated and no script file to relaunch. Run this script from disk, or elevate first.")
  }
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $file))
  $arguments += @('-InstallRoot', ('"{0}"' -f $InstallRoot))
  $arguments += @('-SettingsPath', ('"{0}"' -f $SettingsPath))
  if ($LocalAddress -ne '') { $arguments += @('-LocalAddress', ('"{0}"' -f $LocalAddress)) }
  if ($SkipBuild.IsPresent) { $arguments += '-SkipBuild' }
  if ($SkipPath.IsPresent) { $arguments += '-SkipPath' }
  $arguments += '-Wait'
  Write-Info "Requesting Administrator rights (UAC) to update the hosts file..."
  try {
    Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -Wait | Out-Null
  } catch {
    Fail ("Elevation was cancelled or failed: {0}" -f $_.Exception.Message)
  }
  Write-Ok "Elevated install pass finished."
  exit 0
}

# ---------------------------------------------------------------- pre-flight
Write-Info ("sql-server-mcp installer -- {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Info ("Project root : {0}" -f ${script:ProjectRoot})
Write-Info ("Install root : {0}" -f $InstallRoot)

if ($LocalAddress -ne '') {
  if ($LocalAddress -notmatch '^[A-Za-z0-9]([A-Za-z0-9\-\.]*[A-Za-z0-9])?$') {
    Fail "Invalid -LocalAddress '$LocalAddress'. Use a host name such as sqlserver.local."
  }
  if (-not (Test-Admin) -and -not (Test-HostsEntry $LocalAddress)) { Invoke-Elevated }
}

Ensure-Toolchain

# --------------------------------------------------------------------- build
if ($SkipBuild) {
  Write-Warn "Build skipped (-SkipBuild); using existing $(${script:PublishExe})."
  if (-not (Test-Path ${script:PublishExe})) { Fail "No executable to install at $(${script:PublishExe})." }
} else {
  if ($LocalAddress -eq '' -and -not (Test-Admin)) { Write-Info "Not elevated: hosts file will not be touched." }
  Invoke-Build
}

# ------------------------------------------------------------------- install
Stop-InstalledApp

if (-not (Test-Path $InstallRoot)) {
  New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
  Write-Ok ("Created {0}" -f $InstallRoot)
} else {
  Write-Info ("Install root already exists: {0}" -f $InstallRoot)
}

$settingsDir = Split-Path -Parent $SettingsPath
if ($settingsDir -and -not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }

if (-not (Test-Path $SettingsPath)) {
  $example = Join-Path ${script:ProjectRoot} 'config.example.json'
  if (Test-Path $example) {
    Copy-Item -LiteralPath $example -Destination $SettingsPath -Force
    Write-Ok ("Seeded Settings.json from config.example.json: {0}" -f $SettingsPath)
  } else {
    Set-Content -LiteralPath $SettingsPath -Value '{}' -Encoding ASCII
    Write-Ok ("Created empty Settings.json: {0}" -f $SettingsPath)
  }
} else {
  Write-Info ("Preserving existing settings: {0}" -f $SettingsPath)
}

$dataFile = Join-Path $InstallRoot 'Data.db'
if (-not (Test-Path $dataFile)) {
  New-Item -ItemType File -Path $dataFile -Force | Out-Null
  Write-Ok ("Created {0}" -f $dataFile)
} else {
  Write-Info ("Preserving existing database file: {0}" -f $dataFile)
}

if (Test-Path ${script:TargetExe}) {
  $replaced = $false
  foreach ($attempt in 1..3) {
    try {
      Remove-Item -LiteralPath ${script:TargetExe} -Force
      $replaced = $true
      break
    } catch {
      Write-Warn ("Removing the previous executable failed (attempt {0}): {1}" -f $attempt, $_.Exception.Message)
      Start-Sleep -Seconds 1
    }
  }
  if (-not $replaced) { Fail "Could not replace $(${script:TargetExe}); close it and re-run the installer." }
  Write-Ok "Removed previous executable."
}

Copy-Item -LiteralPath ${script:PublishExe} -Destination ${script:TargetExe} -Force
Write-Ok ("Installed {0}" -f ${script:TargetExe})

# ---------------------------------------------------------------------- path
if ($SkipPath) {
  Write-Warn "User PATH unchanged (-SkipPath)."
} else {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = Split-PathList $userPath
  $present = @($entries | Where-Object { $_.TrimEnd('\') -ieq ${script:PathMarker} })
  if ($present.Count -gt 0) {
    Write-Info "User PATH already contains ${script:PathMarker}"
  } else {
    $joined = (@($entries + ${script:PathMarker}) -join ';')
    [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
    Write-Ok ("Added {0} to the user PATH." -f ${script:PathMarker})
  }
  $env:Path = ([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + ${script:PathMarker})
}

# ------------------------------------------------------------------- settings
if (-not [Environment]::GetEnvironmentVariable('SQL_SERVER_CONFIG', 'User')) {
  [Environment]::SetEnvironmentVariable('SQL_SERVER_CONFIG', $SettingsPath, 'User')
  Write-Ok ("Exported SQL_SERVER_CONFIG for the user: {0}" -f $SettingsPath)
} else {
  Write-Info "SQL_SERVER_CONFIG already set for the user; left untouched."
}

# --------------------------------------------------------------------- hosts
if ($LocalAddress -ne '') {
  if (Test-HostsEntry $LocalAddress) {
    Write-Info ("hosts already maps 127.0.0.1 -> {0}" -f $LocalAddress)
  } else {
    Write-HostsEntry $LocalAddress
  }
  Write-Info ("Configure MCP clients with: {0} launched against --local-address={1}" -f ${script:TargetExe}, $LocalAddress)
} else {
  Write-Info "No -LocalAddress supplied; hosts file untouched."
}

Write-Ok "Install/update complete."
Write-Info ("Executable : {0}" -f ${script:TargetExe})
Write-Info ("Settings   : {0}" -f $SettingsPath)
Write-Info ("Data       : {0}" -f $dataFile)
Write-Info "Next       : edit Settings.json with your SQL Server credentials, then point your MCP client at the executable."
exit 0
