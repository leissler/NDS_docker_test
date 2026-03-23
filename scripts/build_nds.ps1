Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
  [ValidateSet("release", "debug")]
  [string]$Profile = "release",
  [switch]$Latest
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$BuildScript = Join-Path $WorkspaceRoot "build.py"
$Dockerfile = Join-Path $WorkspaceRoot "Dockerfile"
$BuilderImage = if ($env:BUILDER_IMAGE) { $env:BUILDER_IMAGE } else { "ndscompiler-builder" }
$DockerStartTimeout = if ($env:DOCKER_START_TIMEOUT) { [int]$env:DOCKER_START_TIMEOUT } else { 60 }

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

function Has-LocalToolchain {
  $python = Resolve-Python
  if (-not $python) {
    return $false
  }

  $ninja = Get-Command ninja -ErrorAction SilentlyContinue
  if (-not $ninja) {
    return $false
  }

  if (-not $env:BLOCKSDS) {
    return $false
  }

  return (Test-Path $env:BLOCKSDS)
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

function Test-RuntimeReady {
  param([string]$RuntimeExe)
  try {
    & $RuntimeExe info *> $null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  }
}

function Start-DockerDesktop {
  if (-not (Test-Path "C:\Program Files\Docker\Docker\Docker Desktop.exe")) {
    return
  }
  Start-Process -FilePath "C:\Program Files\Docker\Docker\Docker Desktop.exe" | Out-Null
}

function Ensure-ContainerRuntimeReady {
  param([string]$RuntimeExe)

  if (Test-RuntimeReady -RuntimeExe $RuntimeExe) {
    return
  }

  if ([System.IO.Path]::GetFileName($RuntimeExe).ToLowerInvariant() -eq "docker.exe" -or
      [System.IO.Path]::GetFileName($RuntimeExe).ToLowerInvariant() -eq "docker") {
    Write-Output "Docker daemon is not running. Starting Docker Desktop..."
    Start-DockerDesktop
    for ($i = 0; $i -lt $DockerStartTimeout; $i++) {
      Start-Sleep -Seconds 1
      if (Test-RuntimeReady -RuntimeExe $RuntimeExe) {
        Write-Output "Docker Desktop is ready."
        return
      }
    }
    throw "Timed out waiting for Docker Desktop after ${DockerStartTimeout}s."
  }

  throw "Container runtime '$RuntimeExe' is installed but not running."
}

function Invoke-LocalBuild {
  $python = Resolve-Python
  if (-not $python) {
    throw "Python not found."
  }

  $oldProfile = $env:NDS_BUILD_PROFILE
  try {
    $env:NDS_BUILD_PROFILE = $Profile
    $argsList = @()
    $argsList += $python.Prefix
    $argsList += @($BuildScript)
    & $python.Exe @argsList
    if ($LASTEXITCODE -ne 0) {
      throw "Local build failed with exit code $LASTEXITCODE."
    }
  } finally {
    $env:NDS_BUILD_PROFILE = $oldProfile
  }
}

function Ensure-BuilderImage {
  param([string]$RuntimeExe, [bool]$ForceLatest)

  $needsBuild = $ForceLatest
  if (-not $needsBuild) {
    & $RuntimeExe image inspect $BuilderImage *> $null
    $needsBuild = $LASTEXITCODE -ne 0
  }

  if ($needsBuild) {
    if ($ForceLatest) {
      Write-Output "Rebuilding $BuilderImage with latest packages..."
      & $RuntimeExe build --pull --no-cache -f $Dockerfile --target builder -t $BuilderImage $WorkspaceRoot
    } else {
      Write-Output "Docker image $BuilderImage not found, building it..."
      & $RuntimeExe build -f $Dockerfile --target builder -t $BuilderImage $WorkspaceRoot
    }
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to build Docker image $BuilderImage."
    }
  }
}

if (Has-LocalToolchain) {
  Invoke-LocalBuild
  exit 0
}

$runtime = Resolve-ContainerRuntime
if (-not $runtime) {
  throw "No local toolchain and no container runtime found. Install Docker Desktop or BlocksDS toolchain."
}

Ensure-ContainerRuntimeReady -RuntimeExe $runtime
Ensure-BuilderImage -RuntimeExe $runtime -ForceLatest:$Latest

& $runtime run --rm -e "NDS_BUILD_PROFILE=$Profile" -v "$WorkspaceRoot:/test" -w /test $BuilderImage python3 build.py
if ($LASTEXITCODE -ne 0) {
  throw "Container build failed with exit code $LASTEXITCODE."
}
