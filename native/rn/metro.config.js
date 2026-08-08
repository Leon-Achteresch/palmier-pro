const path = require("node:path")
const { getDefaultConfig, mergeConfig } = require("@react-native/metro-config")

const defaults = getDefaultConfig(__dirname)

module.exports = mergeConfig(defaults, {
  resolver: {
    platforms: ["macos", "native", "ios", "android"],
  },
  serializer: {
    // The clock must be installed before React Native wires up its timers, so it leads the polyfills.
    getPolyfills: () => [path.resolve(__dirname, "clock.js"), ...defaults.serializer.getPolyfills()],
  },
})
