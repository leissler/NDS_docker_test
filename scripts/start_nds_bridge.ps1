Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$BridgeScript = Join-Path $ScriptDir "nds_host_bridge.py"
$ConfigFile = if ($env:NDS_BRIDGE_CONFIG) { $env:NDS_BRIDGE_CONFIG } else { Join-Path $WorkspaceRoot ".emulator-bridge.env" }
$Port = if ($env:NDS_BRIDGE_PORT) { $env:NDS_BRIDGE_PORT } else { "17778" }
$BridgeBind = if ($env:NDS_BRIDGE_BIND) { $env:NDS_BRIDGE_BIND } else { "0.0.0.0" }
$RestartBridge = if ($env:NDS_BRIDGE_RESTART) { $env:NDS_BRIDGE_RESTART } else { "1" }
$Emulator = if ($env:NDS_EMULATOR) { $env:NDS_EMULATOR } else { "melonds" }
$EmulatorBin = if ($env:NDS_EMULATOR_BIN) { $env:NDS_EMULATOR_BIN } else { "" }
$GdbPort = if ($env:NDS_GDB_PORT) { $env:NDS_GDB_PORT } else { "3333" }
$GdbBridgePort = if ($env:NDS_BRIDGE_GDB_PORT) { $env:NDS_BRIDGE_GDB_PORT } else { "3335" }
$LogFile = if ($env:NDS_BRIDGE_LOG_FILE) { $env:NDS_BRIDGE_LOG_FILE } else { Join-Path $WorkspaceRoot ".debug-logs\nds-host-bridge.log" }
$ErrLogFile = "${LogFile}.err"
$InitLog = Join-Path $WorkspaceRoot ".devcontainer\nds-bridge-init.log"

function Write-InitLog {
  param([string]$Message)
  $dir = Split-Path -Parent $InitLog
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  Add-Content -Path $InitLog -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
}

function Load-EnvFile {
  param([string]$PathToFile)
  if (-not (Test-Path $PathToFile)) {
    return
  }

  Get-Content -Path $PathToFile | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#")) {
      return
    }

    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)\s*$') {
      $name = $matches[1]
      $value = $matches[2].Trim()
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        if ($value.Length -ge 2) {
          $value = $value.Substring(1, $value.Length - 2)
        }
      }
      Set-Item -Path ("Env:{0}" -f $name) -Value $value
    }
  }
}

function Test-BridgeRunning {
  try {
    Invoke-RestMethod -Method Get -Uri ("http://127.0.0.1:{0}/health" -f $Port) -TimeoutSec 1 | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Stop-Bridge {
  try {
    Invoke-RestMethod -Method Post -Uri ("http://127.0.0.1:{0}/shutdown" -f $Port) -TimeoutSec 1 | Out-Null
  } catch {
    # Ignore and continue with wait checks.
  }

  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Test-BridgeRunning)) {
      return $true
    }
    Start-Sleep -Milliseconds 100
  }

  return $false
}

function Resolve-Python {
  if ($env:PYTHON_BIN) {
    return @{ Exe = $env:PYTHON_BIN; Prefix = @() }
  }

  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) {
    return @{ Exe = $py.Source; Prefix = @("-3") }
  }

  foreach ($candidate in @("python3", "python")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) {
      return @{ Exe = $cmd.Source; Prefix = @() }
    }
  }

  return $null
}

Write-InitLog "start_nds_bridge.ps1 invoked"

$logDir = Split-Path -Parent $LogFile
if ($logDir -and -not (Test-Path $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Load-EnvFile -PathToFile $ConfigFile

$Port = if ($env:NDS_BRIDGE_PORT) { $env:NDS_BRIDGE_PORT } else { $Port }
$BridgeBind = if ($env:NDS_BRIDGE_BIND) { $env:NDS_BRIDGE_BIND } else { $BridgeBind }
$RestartBridge = if ($env:NDS_BRIDGE_RESTART) { $env:NDS_BRIDGE_RESTART } else { $RestartBridge }
$Emulator = if ($env:NDS_EMULATOR) { $env:NDS_EMULATOR } else { $Emulator }
$EmulatorBin = if ($env:NDS_EMULATOR_BIN) { $env:NDS_EMULATOR_BIN } else { $EmulatorBin }
$GdbPort = if ($env:NDS_GDB_PORT) { $env:NDS_GDB_PORT } else { $GdbPort }
$GdbBridgePort = if ($env:NDS_BRIDGE_GDB_PORT) { $env:NDS_BRIDGE_GDB_PORT } else { $GdbBridgePort }

$python = Resolve-Python
if (-not $python) {
  Write-Output "Python not found on host; cannot start NDS emulator bridge automatically."
  Write-InitLog "failed: python not found"
  exit 0
}

if (Test-BridgeRunning) {
  if ($RestartBridge -eq "1") {
    Write-Output ("Restarting host NDS emulator bridge on port {0}..." -f $Port)
    if (-not (Stop-Bridge)) {
      Write-Output ("Warning: could not fully stop existing bridge on port {0}; continuing." -f $Port)
    }
  } else {
    Write-InitLog ("bridge already running on {0}" -f $Port)
    exit 0
  }
}

$argsList = @()
$argsList += $python.Prefix
$argsList += @(
  "-u",
  $BridgeScript,
  "--host", $BridgeBind,
  "--port", "$Port",
  "--workspace-root", $WorkspaceRoot,
  "--emulator", $Emulator,
  "--gdb-port", "$GdbPort",
  "--gdb-bridge-port", "$GdbBridgePort"
)

if ($EmulatorBin) {
  $argsList += @("--emulator-bin", $EmulatorBin)
}

Start-Process -FilePath $python.Exe -ArgumentList $argsList -WindowStyle Hidden -RedirectStandardOutput $LogFile -RedirectStandardError $ErrLogFile | Out-Null

for ($i = 0; $i -lt 20; $i++) {
  if (Test-BridgeRunning) {
    Write-Output ("Host NDS emulator bridge started on port {0} (emulator: {1})." -f $Port, $Emulator)
    Write-InitLog ("started bridge on {0} (emulator: {1})" -f $Port, $Emulator)
    exit 0
  }
  Start-Sleep -Milliseconds 200
}

Write-Output ("Failed to start host NDS emulator bridge. See {0}" -f $LogFile)
Write-InitLog ("failed: see {0}" -f $LogFile)
exit 0
