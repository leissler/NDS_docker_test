# NDS Starter Template (BlocksDS + melonDS)

Starter template for Nintendo DS projects using:
- BlocksDS toolchain
- Nitro Engine + NFLib asset pipeline
- melonDS for run/debug
- Optional VSCode + devcontainer workflow for developers

This template supports two audiences:
- `Users / content creators`: terminal-first workflow, no VSCode required
- `Developers`: VSCode run/debug workflow (host or devcontainer)

## 1. Users / Content Creators (No VSCode Required)

### What you need
- `python3`
- One build path:
1. Local BlocksDS toolchain (`BLOCKSDS` + `ninja`)
2. Docker (Makefile fallback)
- melonDS installed for running ROMs
- `node` (or `nodejs`) only if you want automated `make run*` emulator launch
- On Windows, `make`-based terminal workflow expects Git Bash/WSL. Otherwise, use VSCode/devcontainer workflow.

### Build from terminal
```bash
make build
```

Debug build:
```bash
make build-debug
```

Generated ROM names:
- Release: `<project>.nds` (example: `test.nds`)
- Debug: `<project>-debug.nds` (example: `test-debug.nds`)

### Run from terminal
Build + run release:
```bash
make run
```

Build + run debug:
```bash
make run-debug
```

Run without rebuilding:
```bash
make run-no-build
make run-debug-no-build
```

Clean + rebuild + run:
```bash
make clean-run
make clean-run-debug
```

If you do not want Node-based launch, open the `.nds` file directly in melonDS.

### Content workflow
Place/edit assets in:
- `assets/bg/`
- `assets/sprite/`
- `assets/fnt/`
- `assets/robot/`

Then rebuild with `make build` or `make build-debug`.

## 2. Developers (VSCode Workflow)

### Host VSCode debug
1. Open workspace in VSCode.
2. Set breakpoints in `source/main.c`.
3. Use `Run -> Start Debugging` with `Debug NDS ARM9 (Auto)`.

### Windows 11 preflight (host)
- Install melonDS.
- Install an ARM GDB (`arm-none-eabi-gdb.exe`) and ensure it is in `PATH`.
- If needed, set `NDS_GDB_BIN` to the full gdb executable path.
- If you need to start the host bridge manually:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_nds_bridge.ps1
```

### Devcontainer VSCode debug
1. Reopen in container.
2. Use `Run -> Start Debugging`.
3. The prelaunch pipeline builds debug ROM, starts host bridge/emulator, prepares GDB endpoint, and attaches.

### What this setup does
- Uses melonDS as the primary emulator.
- Enables melonDS GDB stub for debug sessions.
- Uses a host bridge so devcontainer GDB can attach to host melonDS.
- Keeps release and debug builds separate (`-O2` vs `-O0 -g3`).

## 3. Build Profiles

Release (`make build`):
- C flags: `-O2 -DNDEBUG -Wall -std=gnu11`
- ROM: `<project>.nds`

Debug (`make build-debug`):
- C flags: `-O0 -g3 -DDEBUG -Wall -std=gnu11`
- ROM: `<project>-debug.nds`

Artifact separation note:
- Release and debug artifacts are already split by ROM name.
- If you want strict per-OS separation when sharing one workspace between macOS and Windows, set custom ROM names per environment:
  - `NDS_ROM_NAME` for `build.py` runs
  - `NDS_ROM_RELEASE` / `NDS_ROM_DEBUG` for `tools/run-emulator.mjs`
- The safest option is one clone/worktree per OS.

## 4. Useful Commands

Show all make targets:
```bash
make help
```

Clean build outputs:
```bash
make clean
```

Aggressive cleanup (also removes local Docker images used by this project):
```bash
make distclean
```

## 5. Notes and Troubleshooting

- melonDS may print missing `*.ml1` ... `*.ml8` files on startup. These are optional slot files and are harmless.
- If devcontainer debug prelaunch fails, ensure host bridge is running:
```bash
bash scripts/start_nds_bridge.sh
```
- On Windows host, use:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/start_nds_bridge.ps1
```
- Optional bridge overrides can be placed in `.emulator-bridge.env` (see `.emulator-bridge.env.example`).
