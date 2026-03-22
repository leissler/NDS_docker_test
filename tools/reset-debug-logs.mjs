import fs from "node:fs";
import path from "node:path";

const workspaceFolder = process.cwd();
const debugLogDir = process.env.NDS_DEBUG_LOG_DIR || path.join(workspaceFolder, ".debug-logs");
const keepFiles = new Set([
  "nds-host-bridge.log",
  "nds-host-bridge.log.err"
]);

fs.mkdirSync(debugLogDir, { recursive: true });

for (const entry of fs.readdirSync(debugLogDir, { withFileTypes: true })) {
  if (!entry.isFile()) {
    continue;
  }
  if (keepFiles.has(entry.name)) {
    continue;
  }
  fs.rmSync(path.join(debugLogDir, entry.name), { force: true });
}

for (const name of keepFiles) {
  fs.writeFileSync(path.join(debugLogDir, name), "", "utf8");
}

process.stdout.write(`Reset ${debugLogDir} (kept host bridge log files)\n`);
