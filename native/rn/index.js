import React from "react"
import * as ReactNative from "react-native"
import { AppRegistry, View } from "react-native"
import registerCallableModule from "react-native/Libraries/Core/registerCallableModule"
import { transform } from "sucrase"

const timeListeners = new Set()
let currentTimeMs = 0
let fps = 30

function subscribeTime(listener) {
  timeListeners.add(listener)
  return () => timeListeners.delete(listener)
}

/** Seconds into the scene. Use for values a scene must compute per frame. */
function useSceneTime() {
  return React.useSyncExternalStore(
    subscribeTime,
    () => currentTimeMs / 1000,
    () => 0,
  )
}

/** Current frame index, for scenes that think in frames rather than seconds. */
function useSceneFrame() {
  return Math.round(useSceneTime() * fps)
}

const PalmierMotion = { useSceneTime, useSceneFrame }

const MODULES = {
  react: React,
  React,
  "react-native": ReactNative,
}

let sceneError = null

function recordError(error) {
  if (sceneError) return
  sceneError = error && error.stack ? error.stack : String(error)
}

global.__recordError = recordError

function evaluate(source) {
  const { code } = transform(source, {
    transforms: ["typescript", "jsx", "imports"],
    jsxRuntime: "classic",
    filePath: "scene.tsx",
  })

  const moduleExports = {}
  const requireShim = (name) => {
    const module = MODULES[name.replace(/\.(tsx|ts|jsx|js)$/, "")]
    if (module === undefined) {
      throw new Error(`Cannot import "${name}". Available: react, react-native.`)
    }
    return module
  }

  const factory = new Function("require", "exports", "module", "React", "PalmierMotion", code)
  factory(requireShim, moduleExports, { exports: moduleExports }, React, PalmierMotion)

  const component = moduleExports.default ?? moduleExports.Scene ?? moduleExports.Composition
  if (typeof component !== "function") {
    throw new Error("Scene must export a default React component: `export default function Scene() { ... }`")
  }
  return component
}

class SceneBoundary extends React.Component {
  state = { failed: false }
  static getDerivedStateFromError() {
    return { failed: true }
  }
  componentDidCatch(error) {
    recordError(error)
  }
  render() {
    return this.state.failed ? null : this.props.children
  }
}

function Root(props) {
  const Scene = React.useMemo(() => {
    sceneError = null
    if (!props.source) return null
    try {
      return evaluate(props.source)
    } catch (error) {
      recordError(error)
      return null
    }
  }, [props.source])

  if (props.fps > 0) fps = props.fps

  return (
    <View style={{ flex: 1 }}>
      {Scene ? (
        <SceneBoundary>
          <Scene />
        </SceneBoundary>
      ) : null}
    </View>
  )
}

global.__motion = {
  seek(ms) {
    currentTimeMs = ms
    global.__clock.set(ms)
    try {
      global.__clock.flush()
      for (const listener of timeListeners) listener()
    } catch (error) {
      recordError(error)
    }
    return sceneError === null
  },
  status() {
    return { ok: sceneError === null, error: sceneError }
  },
}

// The bake driver reaches the timeline through this; there is no display link offscreen.
registerCallableModule("PalmierMotion", {
  seek: (ms) => global.__motion.seek(ms),
})

AppRegistry.registerComponent("PalmierScene", () => Root)
