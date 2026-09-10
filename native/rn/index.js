import React from "react"
import * as JSXRuntime from "react/jsx-runtime"
import * as JSXDevRuntime from "react/jsx-dev-runtime"
import * as ReactNative from "react-native"
import { AppRegistry, View } from "react-native"
import { parsePath, reduceInstructions } from "@remotion/paths"
import registerCallableModule from "react-native/Libraries/Core/registerCallableModule"
import { transform } from "sucrase"

import * as Palmier from "../../runtime/palmier"
import { createSceneRenderer } from "../../runtime/scene-renderer"
import { sourceFactory, runSource } from "../../runtime/frame-contract"
import { Image, ImageBackground, FrameMarker, resetAssetErrors } from "./frame-readiness"

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

const Shape = ReactNative.requireNativeComponent("PalmierMotionShape")
const Mask = ReactNative.requireNativeComponent("PalmierMotionMask")
const pathCache = new Map()
function pathCommands(path) {
  if(!path)return []
  if(pathCache.has(path))return pathCache.get(path)
  const result=reduceInstructions(parsePath(path))
  pathCache.set(path,result)
  if(pathCache.size>128)pathCache.delete(pathCache.keys().next().value)
  return result
}
const SceneAPI = createSceneRenderer({
  View, Text: ReactNative.Text, Image, native: true, Shape, Mask, pathCommands, evaluateComponent: evaluate,
  useCurrentFrame: Palmier.useCurrentFrame, ...Palmier.PalmierInternals,
})
const PalmierMotion = { ...Palmier, ...SceneAPI, AbsoluteFill, useSceneTime, useSceneFrame }
const SupportedReactNative = new Proxy(ReactNative, {
  get(target, name) {
    if (name === "Image") return Image
    if (name === "ImageBackground") return ImageBackground
    return target[name]
  },
})

const MODULES = {
  react: React,
  "react/jsx-runtime": JSXRuntime,
  "react/jsx-dev-runtime": JSXDevRuntime,
  React,
  "react-native": SupportedReactNative,
  palmier: PalmierMotion,
  remotion: PalmierMotion,
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

  const sceneModule = { exports: {} }
  const requireShim = (name) => {
    const module = MODULES[name.replace(/\.(tsx|ts|jsx|js)$/, "")]
    if (module === undefined) {
      throw new Error(`Cannot import "${name}". Available: react, react-native.`)
    }
    return module
  }

  const factory = sourceFactory(code, ["require", "exports", "module", "React", "PalmierMotion"])
  runSource(factory, [requireShim, sceneModule.exports, sceneModule, React, PalmierMotion])

  const moduleExports = sceneModule.exports
  const component = moduleExports.default ?? moduleExports.Scene ?? moduleExports.Composition
  if (typeof component !== "function" && !(component && typeof component === "object" && "$$typeof" in component)) {
    throw new Error("Scene must export a default React component: `export default function Scene() { ... }`")
  }
  return component
}

let activeDocument = null
let activeRequest = null
let documentGeneration = 0

class SceneBoundary extends React.Component {
  state = { error: null }
  static getDerivedStateFromError(error) { return { error: String(error?.message ?? error) } }
  componentDidCatch(error) { recordError(error) }
  render() {
    const error = this.state.error ?? this.props.error
    return <>
      {error ? null : this.props.children}
      <FrameMarker requestID={this.props.requestID} error={error} />
    </>
  }
}

function Root(props) {
  const request = React.useSyncExternalStore(subscribeTime, () => activeRequest ?? props.requestID)
  const Scene = React.useMemo(() => {
    sceneError = null
    if (!props.source) return null
    try { return evaluate(props.source) }
    catch(error) { recordError(error); return null }
  }, [props.source])
  fps = activeDocument?.fps ?? props.fps
  const frame = useSceneFrame()
  const config = {fps,width:activeDocument?.width ?? props.width,height:activeDocument?.height ?? props.height,
    durationInFrames:activeDocument?.durationInFrames ?? props.durationInFrames}
  return <View style={{flex:1}}>
    <Palmier.PalmierInternals.ConfigContext.Provider value={config}>
      <Palmier.PalmierInternals.TimelineContext.Provider value={{frame}}>
        <SceneBoundary key={documentGeneration} requestID={request} error={sceneError}>
          <SceneAPI.FrameEpochProvider value={request}>
          {activeDocument ? <SceneAPI.SceneDocument document={activeDocument} /> : Scene ? <Scene /> : null}
          </SceneAPI.FrameEpochProvider>
        </SceneBoundary>
      </Palmier.PalmierInternals.TimelineContext.Provider>
    </Palmier.PalmierInternals.ConfigContext.Provider>
  </View>
}

global.__motion = {
  seek(ms, requestID) {
    activeRequest = requestID
    currentTimeMs = ms
    global.__clock.seedRandom((Math.round(ms*fps/1000)^0x9e3779b9)>>>0)
    global.__clock.set(ms)
    for(const listener of timeListeners)listener()
  },
  update(json, requestID) {
    sceneError = null
    resetAssetErrors()
    activeRequest = requestID
    try {
      activeDocument = JSON.parse(json)
      documentGeneration++
      currentTimeMs = Math.min(currentTimeMs, (activeDocument.durationInFrames-1)/activeDocument.fps*1000)
    } catch(error) { recordError(error) }
    for(const listener of timeListeners)listener()
  },
  status() { return {ok:sceneError===null,error:sceneError} },
}

for (const name of ["timing", "spring", "decay", "loop", "sequence", "parallel", "stagger"]) {
  ReactNative.Animated[name] = () => { throw new Error("Native animations must be adapted to scene tracks or useCurrentFrame") }
}

// The bake driver reaches the timeline through this; there is no display link offscreen.
registerCallableModule("PalmierMotion", {
  seek: (ms, requestID) => global.__motion.seek(ms, requestID),
  update: (json, requestID) => global.__motion.update(json, requestID),
})

AppRegistry.registerComponent("PalmierScene", () => Root)
