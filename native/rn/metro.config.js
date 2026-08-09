const path = require("node:path")
const { getDefaultConfig, mergeConfig } = require("@react-native/metro-config")

const defaults = getDefaultConfig(__dirname)

module.exports = mergeConfig(defaults, {
  // The Remotion-shaped scene API lives outside this project so the web runtime shares it verbatim.
  watchFolders: [path.resolve(__dirname, "../../runtime")],
  resolver: {
    platforms: ["macos", "native", "ios", "android"],
    // Modules resolved out of ../../runtime still need this project's dependencies.
    nodeModulesPaths: [path.resolve(__dirname, "node_modules")],
  },
  serializer: {
    // The clock must be installed before React Native wires up its timers, so it leads the polyfills.
    getPolyfills: () => [path.resolve(__dirname, "clock.js"), ...defaults.serializer.getPolyfills()],
  },
})
