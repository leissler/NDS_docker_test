param(
  [switch]$Distclean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$BuildScript = Join-Path $WorkspaceRoot "build.py"

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

function Try-ArchitectdsClean {
  $python = Resolve-Python
  if (-not $python) {
    return
  }

  $argsList = @()
  $argsList += $python.Prefix
  $argsList += @($BuildScript, "--clean")
  & $python.Exe @argsList *> $null
}

function Resolve-ContainerRuntime {
  foreach ($candidate in @("docker", "podman")) {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) {
      return $cmd.Source
    }
  }
  return $null
}

Set-Location $WorkspaceRoot

Try-ArchitectdsClean

Get-ChildItem -Path $WorkspaceRoot -Filter "*.nds" -File -ErrorAction SilentlyContinue | Remove-Item -Force
foreach ($file in @("build.ninja", ".ninja_deps", ".ninja_log")) {
  $path = Join-Path $WorkspaceRoot $file
  if (Test-Path $path) {
    Remove-Item -Force $path
  }
}

foreach ($dir in @("build", "output", "architectds\__pycache__", "scripts\__pycache__", "tools\__pycache__")) {
  $path = Join-Path $WorkspaceRoot $dir
  if (Test-Path $path) {
    Remove-Item -Recurse -Force $path
  }
}

Write-Output "Clean complete."

if (-not $Distclean) {
  exit 0
}

$runtime = Resolve-ContainerRuntime
if (-not $runtime) {
  exit 0
}

& $runtime rmi -f ndscompiler ndscompiler-builder nds-devcontainer nds-devcontainer-test *> $null
Write-Output "Docker image cleanup complete."
