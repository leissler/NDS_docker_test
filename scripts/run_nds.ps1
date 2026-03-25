param(
  [ValidateSet("release", "debug")]
  [string]$Mode = "release",
  [switch]$NoBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$BuildScript = Join-Path $ScriptDir "build_nds.ps1"
$RunScript = Join-Path $WorkspaceRoot "tools\run-emulator.mjs"

if (-not $NoBuild) {
  & $BuildScript -Profile $Mode
  if ($LASTEXITCODE -ne 0) {
    throw "Build failed with exit code $LASTEXITCODE."
  }
}

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
  $nodeCmd = Get-Command nodejs -ErrorAction SilentlyContinue
}
if (-not $nodeCmd) {
  throw "Node.js not found. Install node (or nodejs) to launch the emulator automatically."
}

$oldMode = $env:NDS_LAUNCH_MODE
$oldContext = $env:NDS_LAUNCH_CONTEXT
$oldSkipBuild = $env:NDS_SKIP_BUILD
$oldDebugDir = $env:NDS_DEBUG_LOG_DIR

try {
  $env:NDS_LAUNCH_MODE = $Mode
  $env:NDS_LAUNCH_CONTEXT = "auto"
  $env:NDS_SKIP_BUILD = "1"
  $env:NDS_DEBUG_LOG_DIR = Join-Path $WorkspaceRoot ".debug-logs"

  & $nodeCmd.Source $RunScript
  if ($LASTEXITCODE -ne 0) {
    throw "Emulator launch failed with exit code $LASTEXITCODE."
  }
} finally {
  $env:NDS_LAUNCH_MODE = $oldMode
  $env:NDS_LAUNCH_CONTEXT = $oldContext
  $env:NDS_SKIP_BUILD = $oldSkipBuild
  $env:NDS_DEBUG_LOG_DIR = $oldDebugDir
}
