import * as React from "react"
import * as JSXRuntime from "react/jsx-runtime"
import * as JSXDevRuntime from "react/jsx-dev-runtime"
import * as ReactDOM from "react-dom"
import { createRoot, type Root } from "react-dom/client"
import { flushSync } from "react-dom"
import * as MotionReact from "motion/react"
import * as MotionDom from "motion"
import * as Lucide from "lucide-react"
import { transform } from "sucrase"
import { compile } from "tailwindcss"
import { cn } from "@/lib/utils"

import * as Palmier from "palmier-runtime"
import { createSceneRenderer } from "../../runtime/scene-renderer.js"
import { sourceFactory, runSource } from "../../runtime/frame-contract.js"
import { AbsoluteFill, Img } from "@/lib/remotion"
import * as RemocnUI from "@/lib/remocn-ui"
import * as RemocnIcons from "@/lib/remocn-icons"

import twIndex from "tailwindcss/index.css?raw"
import twPreflight from "tailwindcss/preflight.css?raw"
import twTheme from "tailwindcss/theme.css?raw"
import twUtilities from "tailwindcss/utilities.css?raw"
import appTheme from "./theme.css?raw"

declare global {
  interface Window {
    __clock: {
      seedRandom: (value: number) => void
      set: (ms: number) => void
      now: () => number
      flush: () => number
      pending: () => number
    }
    __recordError?: (error: unknown) => void
    __motion: typeof api
  }
}

const TAILWIND_SOURCES: Record<string, string> = {
  tailwindcss: twIndex,
  "tailwindcss/index": twIndex,
  "tailwindcss/index.css": twIndex,
  "tailwindcss/preflight": twPreflight,
  "tailwindcss/preflight.css": twPreflight,
  "tailwindcss/theme": twTheme,
  "tailwindcss/theme.css": twTheme,
  "tailwindcss/utilities": twUtilities,
  "tailwindcss/utilities.css": twUtilities,
}

const uiModules = import.meta.glob("./components/ui/*.tsx", { eager: true }) as Record<
  string,
  Record<string, unknown>
>

const remocnModules = import.meta.glob("./components/remocn/*.{tsx,ts}", { eager: true }) as Record<
  string,
  Record<string, unknown>
>

const beuiModules = import.meta.glob("./components/beui/**/*.{tsx,ts}", { eager: true }) as Record<
  string,
  Record<string, unknown>
>

const SceneAPI = createSceneRenderer({
  View: "div", Text: "span", Image: "img", native: false, evaluateComponent: evaluate,
  useCurrentFrame: Palmier.useCurrentFrame, ...Palmier.PalmierInternals,
})
const PalmierAPI = { ...Palmier, ...SceneAPI, AbsoluteFill, Img }

const UI: Record<string, unknown> = {}
const MODULES: Record<string, unknown> = {
  palmier: PalmierAPI,
  remotion: PalmierAPI,
  react: React,
  "react/jsx-runtime": JSXRuntime,
  "react/jsx-dev-runtime": JSXDevRuntime,
  "react-dom": ReactDOM,
  "react-dom/client": { createRoot },
  motion: MotionDom,
  "motion/react": MotionReact,
  "framer-motion": MotionReact,
  "lucide-react": Lucide,
  "@/lib/utils": { cn },
  "@/lib/remocn-ui": RemocnUI,
  "@/lib/remocn-icons": RemocnIcons,
}

const REMOCN: Record<string, unknown> = {}

for (const [path, mod] of Object.entries(remocnModules)) {
  const name = path.replace("./components/remocn/", "").replace(/\.(tsx|ts)$/, "")
  for (const alias of [`@/components/remocn/${name}`, `./components/remocn/${name}`, `components/remocn/${name}`]) {
    MODULES[alias] = mod
  }
  for (const [key, value] of Object.entries(mod)) {
    if (!(key in REMOCN)) REMOCN[key] = value
  }
}

for (const [path, mod] of Object.entries(beuiModules)) {
  const name = path.replace("./components/beui/", "").replace(/\.(tsx|ts)$/, "")
  const names = name.endsWith("/index") ? [name, name.replace(/\/index$/, "")] : [name]
  for (const variant of names) {
    for (const alias of [`@/components/beui/${variant}`, `./components/beui/${variant}`, `components/beui/${variant}`]) {
      MODULES[alias] = mod
    }
  }
}

for (const [path, mod] of Object.entries(uiModules)) {
  const name = path.replace("./components/ui/", "").replace(/\.tsx$/, "")
  for (const alias of [`@/components/ui/${name}`, `./components/ui/${name}`, `components/ui/${name}`]) {
    MODULES[alias] = mod
  }
  for (const [key, value] of Object.entries(mod)) {
    if (!(key in UI)) UI[key] = value
  }
}

// MARK: - Scene time

let currentTimeMs = 0
let fps = 30
const timeListeners = new Set<() => void>()

function subscribeTime(listener: () => void) {
  timeListeners.add(listener)
  return () => {
    timeListeners.delete(listener)
  }
}

/** Seconds into the scene. Use for values a scene must compute per frame (counters, paths, physics). */
export function useSceneTime() {
  return React.useSyncExternalStore(
    subscribeTime,
    () => currentTimeMs / 1000,
    () => 0,
  )
}

/** Current frame index, for scenes that think in frames rather than seconds. */
export function useSceneFrame() {
  const seconds = useSceneTime()
  return Math.round(seconds * fps)
}

// MARK: - Error capture

let sceneError: string | null = null

function describe(error: unknown): string {
  if (error instanceof Error) {
    // Safari stacks carry no message line, so prepend it rather than reporting bare frames.
    return error.stack ? `${error.name}: ${error.message}\n${error.stack}` : `${error.name}: ${error.message}`
  }
  return String(error)
}

function recordError(error: unknown) {
  if (sceneError) return
  sceneError = describe(error)
}

window.__recordError = recordError
window.addEventListener("error", (event) => recordError(event.error ?? event.message))
window.addEventListener("unhandledrejection", (event) => recordError(event.reason))

let sceneConfig = { fps: 30, width: 0, height: 0, durationInFrames: 0 }
let frameRequest = 0

function SceneHost({ Scene }: { Scene: React.ComponentType }) {
  const frame = useSceneFrame()
  const epoch = React.useSyncExternalStore(subscribeTime, () => frameRequest, () => 0)
  return (
    <Palmier.PalmierInternals.ConfigContext.Provider value={sceneConfig}>
      <Palmier.PalmierInternals.TimelineContext.Provider value={{ frame }}>
        <SceneBoundary>
          <SceneAPI.FrameEpochProvider value={epoch}>
          <Scene />
          </SceneAPI.FrameEpochProvider>
        </SceneBoundary>
      </Palmier.PalmierInternals.TimelineContext.Provider>
    </Palmier.PalmierInternals.ConfigContext.Provider>
  )
}

class SceneBoundary extends React.Component<{ children: React.ReactNode }, { failed: boolean }> {
  state = { failed: false }
  static getDerivedStateFromError() {
    return { failed: true }
  }
  componentDidCatch(error: unknown) {
    recordError(error)
  }
  render() {
    return this.state.failed ? null : this.props.children
  }
}

// MARK: - Tailwind

let compiler: Awaited<ReturnType<typeof compile>> | null = null
const seenCandidates = new Set<string>()
const styleElement = document.getElementById("tw") as HTMLStyleElement

async function startTailwind() {
  compiler = await compile(appTheme, {
    base: "/",
    loadStylesheet: async (id: string, base: string) => {
      const content = TAILWIND_SOURCES[id]
      if (content === undefined) throw new Error(`Unknown stylesheet import: ${id}`)
      return { path: id, base, content }
    },
    loadModule: async (id: string) => {
      throw new Error(`Tailwind plugins are not available in scenes: ${id}`)
    },
  })
}

/** Rebuilds the stylesheet only when the DOM introduced class names we have not compiled yet. */
function flushStyles() {
  if (!compiler) return
  let added = false
  for (const element of document.querySelectorAll("[class]")) {
    const value = element.getAttribute("class")
    if (!value) continue
    for (const candidate of value.split(/\s+/)) {
      if (candidate && !seenCandidates.has(candidate)) {
        seenCandidates.add(candidate)
        added = true
      }
    }
  }
  if (!added && styleElement.textContent) return
  styleElement.textContent = compiler.build([...seenCandidates])
}

// MARK: - Scene loading

let root: Root | null = null

function evaluate(source: string) {
  const { code } = transform(source, {
    transforms: ["typescript", "jsx", "imports"],
    jsxRuntime: "classic",
    filePath: "scene.tsx",
  })
  const sceneModule: { exports: Record<string, unknown> } = { exports: {} }
  const requireShim = (name: string) => {
    const normalized = name.replace(/\.(tsx|ts|jsx|js)$/, "")
    const mod = MODULES[normalized]
    if (mod === undefined) {
      throw new Error(
        `Cannot import "${name}". Available: react, remotion, motion/react, lucide-react, @/lib/utils, @/lib/remocn-ui, @/lib/remocn-icons, @/components/ui/<component>, @/components/remocn/<component>.`,
      )
    }
    return mod
  }
  const factory = sourceFactory(code, ["require", "exports", "module", "React", "UI", "Remocn", "PalmierMotion"])
  runSource(factory, [requireShim, sceneModule.exports, sceneModule, React, UI, REMOCN, {
    ...PalmierAPI,
    useSceneTime,
    useSceneFrame,
  }])

  const moduleExports = sceneModule.exports
  const component =
    moduleExports.default ?? moduleExports.Scene ?? moduleExports.scene ?? moduleExports.Composition
  if (typeof component !== "function" && !(component && typeof component === "object" && "$$typeof" in component)) {
    throw new Error("Scene must export a default React component: `export default function Scene() { ... }`")
  }
  return component as React.ComponentType
}

let activeDocument: any = null
let documentGeneration = 0

function DocumentRoot() {
  return <SceneAPI.SceneDocument document={activeDocument} />
}

async function assetsSettled() {
  let timeout: ReturnType<typeof setTimeout>
  try {
    await Promise.race([
      Promise.all([document.fonts.ready, ...Array.from(document.images).filter(image => image.src).map(image => image.decode())]),
      new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error("Scene assets did not become ready")), 20000) }),
    ])
  } finally { clearTimeout(timeout!) }
}

function settleFrameCallbacks() {
  let batches = 0
  while (window.__clock.pending()) {
    if (++batches > 32) throw new Error("Continuous imperative animations must be adapted to scene tracks or useCurrentFrame")
    flushSync(() => { window.__clock.flush() })
  }
  if (document.getAnimations().length) throw new Error("CSS and imperative animations must be adapted to scene tracks or useCurrentFrame")
}

const api = {
  async loadDocument(document: any) {
    sceneError = null
    fps = document.fps
    currentTimeMs = Math.min(currentTimeMs, (document.durationInFrames - 1) / fps * 1000)
    sceneConfig = { fps, width: document.width, height: document.height, durationInFrames: document.durationInFrames }
    activeDocument = document
    window.__clock.seedRandom(0x9e3779b9)
    window.__clock.set(currentTimeMs)
    try {
      if (!compiler) await startTailwind()
      if (!root) {
        const container = window.document.getElementById("scene")!
        root = createRoot(container, { onUncaughtError: recordError, onCaughtError: recordError })
      }
      flushSync(() => root!.render(<SceneHost key={++documentGeneration} Scene={DocumentRoot} />))
      settleFrameCallbacks()
      flushStyles()
      await assetsSettled()
      settleFrameCallbacks()
    } catch (error) { recordError(error) }
    return this.status()
  },

  async seek(ms: number) {
    if (!Number.isFinite(ms) || ms < 0 || !activeDocument) throw new Error("Invalid scene time")
    currentTimeMs = ms
    frameRequest++
    window.__clock.seedRandom((Math.round(ms * fps / 1000) ^ 0x9e3779b9) >>> 0)
    window.__clock.set(ms)
    try {
      if (document.getAnimations().length) throw new Error("CSS and imperative animations must be adapted to scene tracks or useCurrentFrame")
      flushSync(() => { for (const listener of timeListeners) listener() })
      settleFrameCallbacks()
      flushStyles()
      await assetsSettled()
      settleFrameCallbacks()
    } catch (error) { recordError(error) }
    return this.status()
  },

  status() { return { ok: sceneError === null, error: sceneError, frame: Math.round(currentTimeMs * fps / 1000) } },
}

window.__motion = api
