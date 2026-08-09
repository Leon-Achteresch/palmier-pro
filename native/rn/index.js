import React from "react"
import * as ReactNative from "react-native"
import { AppRegistry, View } from "react-native"
import registerCallableModule from "react-native/Libraries/Core/registerCallableModule"
import { transform } from "sucrase"

import * as Palmier from "../../runtime/palmier"

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

function AbsoluteFill({ style, children, ...rest }) {
  return React.createElement(View, { style: [Palmier.ABSOLUTE_FILL_STYLE, style], ...rest }, children)
}

const PalmierMotion = { ...Palmier, AbsoluteFill, useSceneTime, useSceneFrame }

const MODULES = {
  react: React,
  React,
  "react-native": ReactNative,
  palmier: PalmierMotion,
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

  const frame = useSceneFrame()
  const config = React.useMemo(
    () => ({
      fps,
      width: props.width ?? 0,
      height: props.height ?? 0,
      durationInFrames: props.durationInFrames ?? 0,
    }),
    [props.width, props.height, props.durationInFrames],
  )

  return (
    <View style={{ flex: 1 }}>
      {Scene ? (
        <Palmier.PalmierInternals.ConfigContext.Provider value={config}>
          <Palmier.PalmierInternals.TimelineContext.Provider value={{ frame }}>
            <SceneBoundary>
              <Scene />
            </SceneBoundary>
          </Palmier.PalmierInternals.TimelineContext.Provider>
        </Palmier.PalmierInternals.ConfigContext.Provider>
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

// The native animation driver runs off CADisplayLink, which an offscreen surface never receives —
// those animations would freeze. Forcing the JS driver puts every Animated value on the virtual clock.
const nativeDriverProps = ["timing", "spring", "decay"]
for (const name of nativeDriverProps) {
  const original = ReactNative.Animated[name]
  ReactNative.Animated[name] = (value, config) => original(value, { ...config, useNativeDriver: false })
}

// The bake driver reaches the timeline through this; there is no display link offscreen.
registerCallableModule("PalmierMotion", {
  seek: (ms) => global.__motion.seek(ms),
})

AppRegistry.registerComponent("PalmierScene", () => Root)
