# NDS Starter Template (BlocksDS + melonDS)

Starter template for Nintendo DS projects using:
- BlocksDS toolchain
- Nitro Engine + NFLib asset pipeline
- melonDS for run/debug
- Optional VSCode + devcontainer workflow for developers

This template supports two audiences:
- `Users / content creators`: friction-free ROM build workflow
- `Developers`: VSCode run/debug workflow (host or devcontainer)

## 1. Content Creators (No Local Toolchain Required)

### Recommended default path (friction-free)
You do **not** need to install the BlocksDS toolchain locally.

Minimum requirements:
- Docker Desktop (or Podman)
- `make` (only if you use the `make ...` commands)
- melonDS (only if you want to run ROMs)
- Node.js only for automated `run` commands (optional)

Windows users can use PowerShell scripts directly (no `make` required).

### Build ROM
macOS/Linux:
```bash
make build
```

Windows PowerShell:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_nds.ps1 -Profile release
```

If Docker uses a remote daemon (for example a Windows VM using Docker context over SSH to a Mac host), set a host-visible mount path first:
```powershell
$env:NDS_WORKSPACE_DIR_MOUNT="/Users/<host-user>/Development/RetroConsoles/NDS/projects/test"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_nds.ps1 -Profile release
```

Debug ROM:
```bash
make build-debug
```

Windows PowerShell debug:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_nds.ps1 -Profile debug
```

### Run ROM
Build + run release:
```bash
make run
```

Windows PowerShell:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_nds.ps1 -Mode release
```

For remote Docker daemon usage, set `NDS_WORKSPACE_DIR_MOUNT` in the same PowerShell session before running `build_nds.ps1` or `run_nds.ps1`.

Build + run debug:
```bash
make run-debug
```

Windows PowerShell debug:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_nds.ps1 -Mode debug
```

Run without rebuilding:
```bash
make run-no-build
make run-debug-no-build
```

Windows PowerShell without rebuild:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_nds.ps1 -Mode release -NoBuild
```

If you don't want automated launch, open the `.nds` file manually in melonDS.

Generated ROM names:
- Release: `<project>.nds` (example: `test.nds`)
- Debug: `<project>-debug.nds` (example: `test-debug.nds`)

### Optional advanced path: local toolchain
This is optional. Use only if you want local native builds instead of Docker fallback.

Local toolchain requirements:
- `python3`
- `ninja`
- BlocksDS installed with `BLOCKSDS` environment variable set

If present, `make build` and `scripts/build_nds.ps1` automatically use the local toolchain.

### Asset workflow
Edit assets in:
- `assets/bg/`
- `assets/sprite/`
- `assets/fnt/`
- `assets/robot/`

Then rebuild (`make build` or `make build-debug`).

## 2. Developers (VSCode)

### Prerequisites
For VSCode workflows:
- VSCode
- Dev Containers extension (for container workflow)
- C/C++ extension (`ms-vscode.cpptools`) for `cppdbg`
- Docker Desktop
- melonDS on host

For host debugging:
- ARM GDB (`arm-none-eabi-gdb`) on host `PATH` or set `NDS_GDB_BIN`
- Node.js on host

For devcontainer debugging:
- Python 3 on host (used by host bridge startup script)

### Host debug
1. Open workspace in VSCode.
2. Set breakpoints in `source/main.c`.
3. Run `Run -> Start Debugging` using `Debug NDS ARM9 (Auto)`.

### Devcontainer debug
1. Reopen in container.
2. Run `Run -> Start Debugging`.
3. Prelaunch pipeline will build debug ROM, launch host emulator through bridge, prepare local GDB endpoint, and attach.

### What the debug setup does
- Uses melonDS as primary emulator.
- Uses melonDS GDB stub for source-level ARM9 debugging.
- Uses host bridge for devcontainer-to-host emulator control.
- Keeps release and debug ROMs separate.

## 3. Build Profiles

Release:
- Command: `make build`
- C flags: `-O2 -DNDEBUG -Wall -std=gnu11`
- ROM: `<project>.nds`

Debug:
- Command: `make build-debug`
- C flags: `-O0 -g3 -DDEBUG -Wall -std=gnu11`
- ROM: `<project>-debug.nds`

## 4. Commands

Show all make targets:
```bash
make help
```

Build latest toolchain image and ROM:
```bash
make build-latest
```

Clean:
```bash
make clean
```

PowerShell clean:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/clean_nds.ps1
```

Distclean:
```bash
make distclean
```

PowerShell distclean:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/clean_nds.ps1 -Distclean
```

## 5. Dependency Matrix

- Build via Docker fallback: `docker` (or `podman`)
- Build via local toolchain: `python3` + `ninja` + `BLOCKSDS`
- Automated run commands: `node` or `nodejs`
- Host debug (`cppdbg`): host ARM GDB + VSCode C/C++
- Devcontainer debug bridge startup: host Python 3

## 6. Notes and Troubleshooting

- melonDS may print missing `*.ml1` ... `*.ml8` files. They are optional save-state slots and harmless.
- Docker fallback uses cached builder image with local stamp file `.docker-stamps/builder.stamp`.
- On macOS and WSL, `make` tries to auto-start Docker Desktop if installed but not running.
- If bridge-related debug prelaunch fails, start the host bridge manually:
```bash
bash scripts/start_nds_bridge.sh
```
- On Windows host:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_nds_bridge.ps1
```
- Optional bridge overrides can be stored in `.emulator-bridge.env` (see `.emulator-bridge.env.example`).

## 7. Artifact Separation

- Debug and release ROM outputs are separated by name by default.
- If you share one workspace across multiple OS hosts, use one clone/worktree per OS for strict isolation.
