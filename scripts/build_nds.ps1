param(
  [ValidateSet("release", "debug")]
  [string]$Profile = "release",
  [switch]$Latest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkspaceRoot = (Resolve-Path (Join-Path $ScriptDir "..")).Path
$BuildScript = Join-Path $WorkspaceRoot "build.py"
$Dockerfile = Join-Path $WorkspaceRoot "Dockerfile"
$BuilderImage = if ($env:BUILDER_IMAGE) { $env:BUILDER_IMAGE } else { "ndscompiler-builder" }
$DockerStartTimeout = if ($env:DOCKER_START_TIMEOUT) { [int]$env:DOCKER_START_TIMEOUT } else { 60 }
$WorkspaceDirMount = if ($env:NDS_WORKSPACE_DIR_MOUNT) {
  $env:NDS_WORKSPACE_DIR_MOUNT
} elseif ($env:NDS_SOURCE_DIR_MOUNT) {
  # Backward-compatible alias with older naming.
  $env:NDS_SOURCE_DIR_MOUNT
} else {
  $WorkspaceRoot
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

function Resolve-ProjectName {
  return [System.IO.Path]::GetFileName($WorkspaceRoot)
}

function Resolve-RomName {
  param([string]$BuildProfile, [string]$ProjectName)

  if ($BuildProfile -eq "debug") {
    return "${ProjectName}-debug.nds"
  }
  return "${ProjectName}.nds"
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

  $runtimeName = [System.IO.Path]::GetFileName($RuntimeExe).ToLowerInvariant()
  if ($runtimeName -eq "docker.exe" -or $runtimeName -eq "docker") {
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

function Get-DockerContextHost {
  param([string]$RuntimeExe)

  $runtimeName = [System.IO.Path]::GetFileName($RuntimeExe).ToLowerInvariant()
  if ($runtimeName -ne "docker.exe" -and $runtimeName -ne "docker") {
    return ""
  }

  try {
    $ctx = (& $RuntimeExe context show 2>$null | Out-String).Trim()
    if (-not $ctx) {
      return ""
    }
    $out = & $RuntimeExe context inspect $ctx --format '{{ .Endpoints.docker.Host }}' 2>$null
    if ($LASTEXITCODE -ne 0) {
      return ""
    }
    return ($out | Out-String).Trim()
  } catch {
    return ""
  }
}

function Invoke-LocalBuild {
  param([string]$RomName)

  $python = Resolve-Python
  if (-not $python) {
    throw "Python not found."
  }

  $oldProfile = $env:NDS_BUILD_PROFILE
  $oldRomName = $env:NDS_ROM_NAME
  try {
    $env:NDS_BUILD_PROFILE = $Profile
    $env:NDS_ROM_NAME = $RomName

    $argsList = @()
    $argsList += $python.Prefix
    $argsList += @($BuildScript)
    & $python.Exe @argsList
    if ($LASTEXITCODE -ne 0) {
      throw "Local build failed with exit code $LASTEXITCODE."
    }
  } finally {
    $env:NDS_BUILD_PROFILE = $oldProfile
    $env:NDS_ROM_NAME = $oldRomName
  }
}

function Ensure-BuilderImage {
  param([string]$RuntimeExe, [bool]$ForceLatest)

  $needsBuild = $ForceLatest
  if (-not $needsBuild) {
    try {
      & $RuntimeExe image inspect $BuilderImage 1>$null 2>$null
      $needsBuild = $LASTEXITCODE -ne 0
    } catch {
      $needsBuild = $true
    }
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

function Try-FetchRomFromMountedWorkspace {
  param(
    [string]$RuntimeExe,
    [string]$ImageName,
    [string]$MountWorkspace,
    [string]$RomName,
    [string]$RomOutPath
  )

  $containerId = ""
  try {
    $containerId = (& $RuntimeExe create -v "${MountWorkspace}:/test:ro" $ImageName sh -c "sleep 300" 2>$null | Out-String).Trim()
    if (-not $containerId) {
      return $false
    }

    & $RuntimeExe start $containerId 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
      return $false
    }

    & $RuntimeExe exec $containerId test -f "/test/$RomName" 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
      return $false
    }

    & $RuntimeExe cp "${containerId}:/test/$RomName" $RomOutPath 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
      return $false
    }

    return $true
  } catch {
    return $false
  } finally {
    if ($containerId) {
      & $RuntimeExe rm -f $containerId 1>$null 2>$null
    }
  }
}

$projectName = Resolve-ProjectName
$romName = Resolve-RomName -BuildProfile $Profile -ProjectName $projectName
$romPath = Join-Path $WorkspaceRoot $romName

if (Has-LocalToolchain) {
  Invoke-LocalBuild -RomName $romName
  exit 0
}

$runtime = Resolve-ContainerRuntime
if (-not $runtime) {
  throw "No local toolchain and no container runtime found. Install Docker Desktop or BlocksDS toolchain."
}

Ensure-ContainerRuntimeReady -RuntimeExe $runtime

$daemonHost = Get-DockerContextHost -RuntimeExe $runtime
$isRemoteDockerDaemon = $false
if ($daemonHost -and -not $daemonHost.StartsWith("unix://") -and -not $daemonHost.StartsWith("npipe://")) {
  $isRemoteDockerDaemon = $true
  if (-not $env:NDS_WORKSPACE_DIR_MOUNT -and -not $env:NDS_SOURCE_DIR_MOUNT) {
    throw "Detected remote Docker daemon '$daemonHost'. Set NDS_WORKSPACE_DIR_MOUNT to a workspace path on the daemon host."
  }
}

Ensure-BuilderImage -RuntimeExe $runtime -ForceLatest:$Latest

& $runtime run --rm -e "NDS_BUILD_PROFILE=$Profile" -e "NDS_ROM_NAME=$romName" -v "${WorkspaceDirMount}:/test" -w /test $BuilderImage python3 build.py
if ($LASTEXITCODE -ne 0) {
  throw "Container build failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path $romPath)) {
  $fetched = Try-FetchRomFromMountedWorkspace -RuntimeExe $runtime -ImageName $BuilderImage -MountWorkspace $WorkspaceDirMount -RomName $romName -RomOutPath $romPath
  if (-not $fetched) {
    throw "Build succeeded but '$romName' was not found locally and could not be copied from mounted workspace. If using a remote daemon, verify NDS_WORKSPACE_DIR_MOUNT."
  }
}

Write-Output ("Built ./{0}" -f $romName)
