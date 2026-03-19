import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

import emulatorConfig from "./emulators.config.mjs";

const workspaceFolder = process.cwd();
const projectName = path.basename(workspaceFolder);
const launchContext = process.env.NDS_LAUNCH_CONTEXT || "auto";
const inContainer = isInContainer();

const isDebugLaunch = detectDebugLaunch();
const buildTarget = isDebugLaunch ? "build-debug" : "build";
const buildProfile = isDebugLaunch ? "debug" : "release";
const releaseRom = process.env.NDS_ROM_RELEASE || `${projectName}.nds`;
const debugRom = process.env.NDS_ROM_DEBUG || `${projectName}-debug.nds`;
const romPath = path.resolve(workspaceFolder, isDebugLaunch ? debugRom : releaseRom);
const gdbPort = resolveGdbPort();
const hostMelondsGdbPort = resolveHostMelondsGdbPort(gdbPort);
const bridgeStateFile = resolveBridgeStateFile();

main().catch((error) => {
  if (error instanceof Error) {
    fail(error.message);
  }
  fail(String(error));
});

async function main() {
  if (process.env.NDS_SKIP_BUILD !== "1") {
    runBuild(buildTarget, buildProfile);
  }

  if (!fs.existsSync(romPath)) {
    fail(`ROM not found: ${romPath}`);
  }

  const shouldUseHostBridge = (
    launchContext === "host" ||
    (launchContext !== "remote" && process.platform === "linux" && inContainer)
  );

  if (shouldUseHostBridge) {
    await launchRomOnHostViaBridge(romPath, isDebugLaunch);
    return;
  }

  const emulator = discoverEmulator();
  if (!emulator) {
    fail(noEmulatorMessage());
  }

  const argsTemplate = isDebugLaunch
    ? (emulator.argsDebug || emulator.argsRelease || ["${rom}"])
    : (emulator.argsRelease || ["${rom}"]);

  const args = argsTemplate.map((arg) => expandTemplate(arg, romPath));

  log(`Launching ${emulator.name}: ${emulator.binary}`);
  log(`ROM: ${romPath}`);
  runCommand(emulator.binary, args, workspaceFolder);
}

function detectDebugLaunch() {
  if (process.env.NDS_LAUNCH_MODE === "debug") {
    return true;
  }
  if (process.env.NDS_LAUNCH_MODE === "release") {
    return false;
  }
  if (process.env.VSCODE_INSPECTOR_OPTIONS) {
    return true;
  }
  return process.execArgv.some((arg) => arg.includes("--inspect"));
}

function discoverEmulator() {
  const platform = process.platform;
  if (platform !== "darwin" && platform !== "win32" && platform !== "linux") {
    fail(`Unsupported platform '${platform}'.`);
  }

  const preferredFromEnv = (process.env.NDS_EMULATOR || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

  const debugPreferred = isDebugLaunch ? ["melonds"] : [];
  const order = [
    ...preferredFromEnv,
    ...debugPreferred,
    ...(emulatorConfig.preferredOrder || []),
    ...Object.keys(emulatorConfig.emulators || {})
  ].filter(uniqueItems);

  const emulatorPathOverride = process.env.NDS_EMULATOR_PATH;
  for (const name of order) {
    const def = emulatorConfig.emulators?.[name];
    if (!def) {
      continue;
    }

    const platformDef = def.platforms?.[platform] || def.platforms?.default;
    if (!platformDef) {
      continue;
    }

    const candidates = [];
    if (emulatorPathOverride) {
      candidates.push(emulatorPathOverride);
    }
    candidates.push(...(platformDef.candidates || []));

    for (const candidate of candidates) {
      const resolved = resolveExecutable(candidate);
      if (resolved) {
        return {
          id: name,
          name: def.displayName || name,
          binary: resolved,
          argsRelease: platformDef.argsRelease,
          argsDebug: platformDef.argsDebug
        };
      }
    }
  }

  return null;
}

function resolveExecutable(candidate) {
  const expanded = expandPath(candidate);
  if (!expanded) {
    return null;
  }

  if (looksLikePath(expanded)) {
    return isExecutable(expanded) ? expanded : null;
  }
  return findCommandInPath(expanded);
}

async function launchRomOnHostViaBridge(containerRomPath, debug) {
  const port = resolveBridgePort();
  const candidates = collectBridgeHosts();
  let bridgeHost = null;

  for (const candidate of candidates) {
    if (await bridgeHealth(candidate, port)) {
      bridgeHost = candidate;
      break;
    }
  }

  if (!bridgeHost) {
    fail(
      "Host emulator bridge is not reachable.\n" +
      `Port: ${port}\n` +
      `Checked hosts: ${candidates.join(", ")}\n` +
      "Run on host: bash scripts/start_nds_bridge.sh"
    );
  }

  const emulatorOverride = firstCsvValue(process.env.NDS_EMULATOR) || (debug ? "melonds" : "");
  const emulatorBinOverride = process.env.NDS_EMULATOR_PATH || process.env.NDS_EMULATOR_BIN || "";
  const payload = {
    rom: process.env.NDS_BRIDGE_ROM || path.basename(containerRomPath),
    debug: Boolean(debug)
  };

  if (emulatorOverride) {
    payload.emulator = emulatorOverride;
  }
  if (emulatorBinOverride) {
    payload.emulator_bin = emulatorBinOverride;
  }
  if (debug) {
    // Keep local debugger endpoint stable (127.0.0.1:3333) but allow host-side
    // melonDS to use a different GDB port in container workflows to avoid
    // localhost forwarding loops on host port 3333.
    payload.gdb_port = hostMelondsGdbPort;
  }

  const response = await bridgeRequest(
    bridgeHost,
    port,
    "/launch",
    "POST",
    JSON.stringify(payload),
    debug ? 12000 : 2500
  );

  if (response.statusCode !== 200) {
    fail(
      `Host emulator bridge launch failed (HTTP ${response.statusCode}).\n` +
      truncateBody(response.body)
    );
  }

  let payloadResponse = {};
  try {
    payloadResponse = JSON.parse(response.body || "{}");
  } catch {
    payloadResponse = {};
  }

  const localGdbPort = Number.parseInt(String(payloadResponse.gdb_port || gdbPort), 10);
  const bridgeGdbPort = Number.parseInt(String(payloadResponse.gdb_bridge_port || ""), 10);
  if (inContainer && (!Number.isFinite(bridgeGdbPort) || bridgeGdbPort <= 0)) {
    fail(
      "Host bridge did not provide a usable gdb_bridge_port for container debugging.\n" +
      "Restart the host bridge (scripts/start_nds_bridge.sh) and retry."
    );
  }
  const selectedGdbPort = inContainer ? bridgeGdbPort : localGdbPort;

  writeBridgeState({
    bridgeHost,
    bridgePort: port,
    gdbHost: String(payloadResponse.gdb_host || bridgeHost),
    gdbPort: selectedGdbPort,
    timestamp: new Date().toISOString()
  });

  log(`Requested host emulator launch for ${payload.rom} via ${bridgeHost}:${port}`);
}

function resolveBridgePort() {
  const raw = process.env.NDS_BRIDGE_PORT || "17778";
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0 || parsed > 65535) {
    fail(`Invalid NDS_BRIDGE_PORT value: ${raw}`);
  }
  return parsed;
}

function resolveGdbPort() {
  const raw = process.env.NDS_GDB_PORT || "3333";
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0 || parsed > 65535) {
    fail(`Invalid NDS_GDB_PORT value: ${raw}`);
  }
  return parsed;
}

function resolveHostMelondsGdbPort(defaultPort) {
  const defaultValue = inContainer ? 7333 : defaultPort;
  const raw = process.env.NDS_HOST_MELONDS_GDB_PORT || String(defaultValue);
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed <= 0 || parsed > 65535) {
    fail(`Invalid NDS_HOST_MELONDS_GDB_PORT value: ${raw}`);
  }
  return parsed;
}

function resolveBridgeStateFile() {
  const fromEnv = (process.env.NDS_BRIDGE_STATE_FILE || "").trim();
  if (fromEnv) {
    return fromEnv;
  }
  return path.join(workspaceFolder, ".debug-logs", "nds-bridge-state.json");
}

function writeBridgeState(state) {
  try {
    fs.mkdirSync(path.dirname(bridgeStateFile), { recursive: true });
    fs.writeFileSync(bridgeStateFile, JSON.stringify(state), "utf8");
  } catch {
    // Best effort only.
  }
}

function collectBridgeHosts() {
  const list = [];
  const explicit = firstCsvValue(process.env.NDS_BRIDGE_HOST);
  if (explicit) {
    list.push(explicit);
  }

  if (!inContainer) {
    list.push("127.0.0.1", "localhost");
  }

  list.push(
    "host.docker.internal",
    "gateway.docker.internal",
    "host.containers.internal",
    "docker.for.mac.host.internal"
  );

  const routeGateway = readProcRouteGateway();
  if (routeGateway) {
    list.push(routeGateway);
  }

  list.push("192.168.65.1", "172.17.0.1");

  return list.filter(uniqueItems);
}

function readProcRouteGateway() {
  try {
    const routeFile = "/proc/net/route";
    if (!fs.existsSync(routeFile)) {
      return null;
    }
    const rows = fs.readFileSync(routeFile, "utf8").split(/\r?\n/);
    for (let i = 1; i < rows.length; i += 1) {
      const row = rows[i].trim();
      if (!row) {
        continue;
      }
      const parts = row.split(/\s+/);
      if (parts.length < 3) {
        continue;
      }
      const destination = parts[1];
      const gatewayHex = parts[2];
      if (destination !== "00000000" || !/^[0-9A-Fa-f]{8}$/.test(gatewayHex)) {
        continue;
      }
      const octets = [
        Number.parseInt(gatewayHex.slice(6, 8), 16),
        Number.parseInt(gatewayHex.slice(4, 6), 16),
        Number.parseInt(gatewayHex.slice(2, 4), 16),
        Number.parseInt(gatewayHex.slice(0, 2), 16)
      ];
      if (octets.every((v) => Number.isInteger(v) && v >= 0 && v <= 255)) {
        return octets.join(".");
      }
    }
  } catch {
    return null;
  }
  return null;
}

async function bridgeHealth(host, port) {
  try {
    const response = await bridgeRequest(host, port, "/health", "GET", null, 800);
    return response.statusCode === 200;
  } catch {
    return false;
  }
}

function bridgeRequest(host, port, reqPath, method, body, timeoutMs) {
  return new Promise((resolve, reject) => {
    const headers = {};
    if (body !== null) {
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = String(Buffer.byteLength(body));
    }

    const request = http.request(
      {
        host,
        port,
        path: reqPath,
        method,
        timeout: timeoutMs,
        headers
      },
      (response) => {
        let responseBody = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => {
          responseBody += chunk;
        });
        response.on("end", () => {
          resolve({
            statusCode: response.statusCode || 0,
            body: responseBody
          });
        });
      }
    );

    request.on("error", (error) => {
      reject(error);
    });

    request.on("timeout", () => {
      request.destroy(new Error(`Request timed out after ${timeoutMs}ms`));
    });

    if (body !== null) {
      request.write(body);
    }
    request.end();
  });
}

function firstCsvValue(input) {
  return (input || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)[0] || "";
}

function truncateBody(body) {
  const text = (body || "").trim();
  if (!text) {
    return "(empty response)";
  }
  return text.length > 600 ? `${text.slice(0, 600)}...` : text;
}

function findMakeCommand() {
  for (const cmd of ["make", "mingw32-make"]) {
    const resolved = findCommandInPath(cmd);
    if (resolved) {
      return resolved;
    }
  }
  return null;
}

function findPythonCommand() {
  const python3 = findCommandInPath("python3");
  if (python3) {
    return { command: python3, prefixArgs: [] };
  }

  const python = findCommandInPath("python");
  if (python) {
    return { command: python, prefixArgs: [] };
  }

  const py = findCommandInPath("py");
  if (py) {
    return { command: py, prefixArgs: ["-3"] };
  }

  return null;
}

function runBuild(target, profile) {
  const makeCmd = findMakeCommand();
  if (makeCmd) {
    log(`Building (${profile}) via: ${makeCmd} ${target}`);
    runCommand(makeCmd, [target], workspaceFolder);
    return;
  }

  const python = findPythonCommand();
  const hasLocalToolchain = Boolean(
    python &&
    findCommandInPath("ninja") &&
    process.env.BLOCKSDS &&
    fs.existsSync(process.env.BLOCKSDS)
  );

  if (inContainer || hasLocalToolchain) {
    if (!python) {
      fail("Python was not found but is required for local/container build.");
    }
    log(`Building (${profile}) via local Python toolchain`);
    runCommand(
      python.command,
      [...python.prefixArgs, "build.py"],
      workspaceFolder,
      { ...process.env, NDS_BUILD_PROFILE: profile }
    );
    return;
  }

  const docker = findCommandInPath(process.platform === "win32" ? "docker.exe" : "docker");
  if (docker) {
    log(`Building (${profile}) via Docker fallback`);
    runCommand(docker, ["build", "-f", "Dockerfile", "--target", "builder", "-t", "ndscompiler-builder", "."], workspaceFolder);
    runCommand(
      docker,
      ["run", "--rm", "-e", `NDS_BUILD_PROFILE=${profile}`, "-v", `${workspaceFolder}:/test`, "-w", "/test", "ndscompiler-builder", "python3", "build.py"],
      workspaceFolder
    );
    return;
  }

  fail(
    "No build environment found.\n" +
    "Install make, or configure local BlocksDS toolchain (BLOCKSDS + ninja + python), or install Docker."
  );
}

function isInContainer() {
  return fs.existsSync("/.dockerenv") || Boolean(process.env.REMOTE_CONTAINERS);
}

function findCommandInPath(command) {
  const pathEnv = process.env.PATH || "";
  const folders = pathEnv.split(path.delimiter).filter(Boolean);
  const extensions = process.platform === "win32"
    ? (process.env.PATHEXT || ".EXE;.CMD;.BAT;.COM").split(";")
    : [""];

  const hasExt = path.extname(command).length > 0;
  for (const folder of folders) {
    if (!folder) {
      continue;
    }

    if (process.platform === "win32") {
      if (hasExt) {
        const full = path.join(folder, command);
        if (isExecutable(full)) {
          return full;
        }
      } else {
        for (const ext of extensions) {
          const full = path.join(folder, `${command}${ext}`);
          if (isExecutable(full)) {
            return full;
          }
        }
      }
    } else {
      const full = path.join(folder, command);
      if (isExecutable(full)) {
        return full;
      }
    }
  }

  return null;
}

function expandPath(input) {
  if (!input) {
    return input;
  }

  let value = input;
  if (value.startsWith("~")) {
    value = path.join(os.homedir(), value.slice(1));
  }

  value = value.replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, (_, name) => process.env[name] || "");
  value = value.replace(/%([^%]+)%/g, (_, name) => process.env[name] || "");
  return value;
}

function expandTemplate(template, rom) {
  return template
    .replaceAll("${rom}", rom)
    .replaceAll("${gdbPort}", String(gdbPort))
    .replaceAll("${workspaceFolder}", workspaceFolder)
    .replaceAll("${cwd}", workspaceFolder);
}

function looksLikePath(value) {
  return path.isAbsolute(value) || value.includes("/") || value.includes("\\");
}

function isExecutable(filePath) {
  if (!fs.existsSync(filePath)) {
    return false;
  }

  if (process.platform === "win32") {
    return true;
  }

  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function runCommand(command, args, cwd, env = process.env) {
  const result = spawnSync(command, args, {
    cwd,
    env,
    stdio: "inherit"
  });

  if (result.error) {
    fail(`Failed to run command: ${command}\n${result.error.message}`);
  }
  if (result.status !== 0) {
    process.exit(result.status || 1);
  }
}

function uniqueItems(value, index, list) {
  return list.indexOf(value) === index;
}

function log(message) {
  process.stdout.write(`[nds-launch] ${message}\n`);
}

function fail(message) {
  process.stderr.write(`[nds-launch] ${message}\n`);
  process.exit(1);
}

function noEmulatorMessage() {
  return [
    "No supported NDS emulator was found on this machine.",
    "Checked emulator definitions in tools/emulators.config.mjs.",
    "Set NDS_EMULATOR and/or NDS_EMULATOR_PATH to override discovery."
  ].join("\n");
}
