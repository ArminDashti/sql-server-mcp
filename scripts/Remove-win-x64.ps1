#Requires -Version 5.1
<#
  sql-server-mcp -- Windows x64 uninstaller.

  Stops every running sql-server-mcp process, deletes %LOCALAPPDATA%\SqlServerMcp
  with all settings, logs and data, drops the folder from the user PATH, clears
  the SQL_SERVER_CONFIG user variable and removes the hosts entries this project
  added (hosts work needs Administrator).

  Examples:
    powershell -ExecutionPolicy Bypass -File .\scripts\Remove-win-x64.ps1
    powershell -ExecutionPolicy Bypass -File .\scripts\Remove-win-x64.ps1 -LocalAddress sqlserver.local
#>
[CmdletBinding()]
param(
  [string]$LocalAddress = "",
  [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "SqlServerMcp"),
  [switch]$KeepSettings,
  [switch]$AllowElevation = $true,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:AppName    = "sql-server-mcp"
$script:ExeName    = "sql-server-mcp.exe"
$script:TargetExe  = Join-Path $InstallRoot ${script:ExeName}
$script:HostsFile  = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
$script:PathMarker = $InstallRoot.TrimEnd('\')

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

function Remove-InstallFolder {
  if (-not (Test-Path $InstallRoot)) {
    Write-Info ("Nothing to delete at {0}" -f $InstallRoot)
    return
  }
  foreach ($attempt in 1..3) {
    try {
      if ($KeepSettings) {
        Get-ChildItem -LiteralPath $InstallRoot -Force | ForEach-Object {
          Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
        Write-Ok ("Deleted every file under {0}, keeping the {1} folder for your settings." -f $InstallRoot, ${script:AppName})
      } else {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction Stop
        Write-Ok ("Deleted {0} and all contents." -f $InstallRoot)
      }
      return
    } catch {
      Write-Warn ("Delete attempt {0} failed: {1}" -f $attempt, $_.Exception.Message)
      Get-Processes | ForEach-Object { try { [void]$_.Kill() } catch { } }
      Start-Sleep -Seconds 1
    }
  }
  Fail "Could not delete $InstallRoot. Close every sql-server-mcp process and retry."
}

function Remove-FromUserPath {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = Split-PathList $userPath
  $remaining = @($entries | Where-Object { $_.TrimEnd('\') -ine ${script:PathMarker} })
  if ($remaining.Count -eq $entries.Count) {
    Write-Info "User PATH does not contain ${script:PathMarker}"
    return
  }
  [Environment]::SetEnvironmentVariable('Path', ($remaining -join ';'), 'User')
  Write-Ok ("Removed {0} from the user PATH." -f ${script:PathMarker})
}

function Get-HostsEntries {
  if (-not (Test-Path ${script:HostsFile})) { return @() }
  return @(Get-Content -LiteralPath ${script:HostsFile})
}

function Test-HostsLine {
  param([string]$Address, [string[]]$Lines)
  foreach ($line in $Lines) {
    if ([regex]::IsMatch($line, ('^\s*127\.0\.0\.1\s+' + [regex]::Escape($Address) + '\s*$')) -or
        [regex]::IsMatch($line, ('^#\s+sql-server-mcp\s+' + [regex]::Escape($Address) + '\s*$'))) {
      return $true
    }
  }
  return $false
}

function Get-ManagedHostsNames {
  param([string[]]$Lines)
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($line in $Lines) {
    $match = [regex]::Match($line, '^#\s+sql-server-mcp\s+(?<name>\S+)\s*$')
    if ($match.Success) { [void]$names.Add($match.Groups['name'].Value) }
  }
  return $names
}

function Remove-HostsEntries {
  $lines = Get-HostsEntries
  $managed = Get-ManagedHostsNames $lines
  $targets = New-Object System.Collections.Generic.List[string]
  foreach ($name in $managed) { [void]$targets.Add($name) }
  if ($LocalAddress -ne '') {
    if (-not $targets.Contains($LocalAddress)) { [void]$targets.Add($LocalAddress) }
  }
  $toRemove = @($targets | Where-Object { Test-HostsLine -Address $_ -Lines $lines })
  if ($toRemove.Count -eq 0) {
    Write-Info "No sql-server-mcp hosts entries found; nothing to clean."
    return
  }
  if (-not (Test-Admin)) {
    if (-not $AllowElevation) {
      Fail ("Administrator rights are required to remove the hosts entries for {0}." -f ($toRemove -join ', '))
    }
    Invoke-Elevated
    return
  }
  $kept = @($lines | Where-Object {
    $line = $_
    $drop = $false
    foreach ($name in $targets) {
      if ([regex]::IsMatch($line, ('^\s*127\.0\.0\.1\s+' + [regex]::Escape($name) + '\s*$')) -or
          [regex]::IsMatch($line, ('^#\s+sql-server-mcp\s+' + [regex]::Escape($name) + '\s*$'))) {
        $drop = $true
        break
      }
    }
    -not $drop
  })
  Set-Content -LiteralPath ${script:HostsFile} -Value $kept -Encoding ASCII
  Write-Ok ("Removed hosts entries for: {0}" -f ($targets -join ', '))
}

function Invoke-Elevated {
  if (-not $AllowElevation) {
    Fail "Administrator rights are required to clean the hosts file. Re-run from an elevated prompt."
  }
  $exe = (Get-Process -Id $PID).Path
  $file = $PSCommandPath
  if (-not $file) {
    Fail "Not elevated and no script file to relaunch. Run this script from disk, or elevate first."
  }
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $file))
  $arguments += @('-InstallRoot', ('"{0}"' -f $InstallRoot))
  if ($LocalAddress -ne '') { $arguments += @('-LocalAddress', ('"{0}"' -f $LocalAddress)) }
  if ($KeepSettings.IsPresent) { $arguments += '-KeepSettings' }
  $arguments += '-Wait'
  Write-Info "Requesting Administrator rights (UAC) to clean the hosts file..."
  try {
    Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -Wait | Out-Null
  } catch {
    Fail ("Elevation was cancelled or failed: {0}" -f $_.Exception.Message)
  }
  Write-Ok "Elevated uninstall pass finished."
  exit 0
}

# ---------------------------------------------------------------- pre-flight
Write-Info ("sql-server-mcp uninstaller -- {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Info ("Install root : {0}" -f $InstallRoot)
if ($LocalAddress -ne '' -and $LocalAddress -notmatch '^[A-Za-z0-9]([A-Za-z0-9\-\.]*[A-Za-z0-9])?$') {
  Fail "Invalid -LocalAddress '$LocalAddress'. Use a host name such as sqlserver.local."
}

# ------------------------------------------------------------- hosts preview
$probe = Get-HostsEntries
$pending = @(Get-ManagedHostsNames $probe)
if ($LocalAddress -ne '' -and -not ($pending -contains $LocalAddress)) {
  $pending = @($pending + $LocalAddress)
}
$present = @($pending | Where-Object { Test-HostsLine -Address $_ -Lines $probe })
if ($present.Count -gt 0 -and -not (Test-Admin) -and -not $AllowElevation) {
  Write-Warn ("Not elevated: hosts entries for {0} cannot be removed in this pass." -f ($present -join ', '))
}

# ------------------------------------------------------------------ lifecycle
Stop-InstalledApp
Remove-InstallFolder

Remove-FromUserPath

if ([Environment]::GetEnvironmentVariable('SQL_SERVER_CONFIG', 'User')) {
  if ($KeepSettings) {
    Write-Info "SQL_SERVER_CONFIG kept (-KeepSettings)."
  } else {
    [Environment]::SetEnvironmentVariable('SQL_SERVER_CONFIG', $null, 'User')
    Write-Ok "Cleared the SQL_SERVER_CONFIG user variable."
  }
} else {
  Write-Info "SQL_SERVER_CONFIG was not set; nothing to clear."
}

Remove-HostsEntries

Write-Ok "Uninstall complete."
Write-Info ("Executable gone : {0}" -f (-not (Test-Path ${script:TargetExe})))
Write-Info ("Folder gone     : {0}" -f (-not (Test-Path $InstallRoot)))
exit 0
