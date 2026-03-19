export const emulatorConfig = {
  preferredOrder: [
    "melonds"
  ],
  emulators: {
    melonds: {
      displayName: "melonDS",
      platforms: {
        darwin: {
          candidates: [
            "melonDS",
            "/Applications/melonDS.app/Contents/MacOS/melonDS",
            "/Applications/melonDS.app/Contents/MacOS/melonDS-arm64",
            "/Applications/melonDS.app/Contents/MacOS/melonDS-x86_64"
          ],
          argsRelease: ["${rom}"],
          // melonDS CLI has no dedicated "debug UI" switch in current upstream.
          // We still run the debug ROM when VSCode starts with debugging.
          argsDebug: ["${rom}"]
        },
        win32: {
          candidates: [
            "melonDS.exe",
            "melonDS",
            "%LOCALAPPDATA%\\Programs\\melonDS\\melonDS.exe",
            "C:\\Program Files\\melonDS\\melonDS.exe",
            "C:\\Program Files (x86)\\melonDS\\melonDS.exe"
          ],
          argsRelease: ["${rom}"],
          argsDebug: ["${rom}"]
        },
        linux: {
          candidates: [
            "melonds",
            "melonDS"
          ],
          argsRelease: ["${rom}"],
          argsDebug: ["${rom}"]
        }
      }
    }
    // Example custom emulator entry:
    // custom: {
    //   displayName: "Custom Emulator",
    //   platforms: {
    //     darwin: {
    //       candidates: ["/Applications/Custom.app/Contents/MacOS/custom"],
    //       argsRelease: ["${rom}"],
    //       argsDebug: ["--debug-ui", "${rom}"]
    //     },
    //     win32: {
    //       candidates: ["C:\\\\Tools\\\\custom.exe"],
    //       argsRelease: ["${rom}"],
    //       argsDebug: ["--debug-ui", "${rom}"]
    //     }
    //   }
    // }
  }
};

export default emulatorConfig;
