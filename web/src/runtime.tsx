import * as React from "react"
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

const PalmierAPI = { ...Palmier, AbsoluteFill, Img }

const UI: Record<string, unknown> = {}
const MODULES: Record<string, unknown> = {
  palmier: PalmierAPI,
  remotion: PalmierAPI,
  react: React,
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

function SceneHost({ Scene }: { Scene: React.ComponentType }) {
  const frame = useSceneFrame()
  return (
    <Palmier.PalmierInternals.ConfigContext.Provider value={sceneConfig}>
      <Palmier.PalmierInternals.TimelineContext.Provider value={{ frame }}>
        <SceneBoundary>
          <Scene />
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
  const moduleExports: Record<string, unknown> = {}
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
  const factory = new Function("require", "exports", "module", "React", "UI", "Remocn", "PalmierMotion", code)
  factory(requireShim, moduleExports, { exports: moduleExports }, React, UI, REMOCN, {
    ...PalmierAPI,
    useSceneTime,
    useSceneFrame,
  })

  const component =
    moduleExports.default ?? moduleExports.Scene ?? moduleExports.scene ?? moduleExports.Composition
  if (typeof component !== "function") {
    throw new Error("Scene must export a default React component: `export default function Scene() { ... }`")
  }
  return component as React.ComponentType
}

/// The renderer hosts an offscreen window, which never gets display-link callbacks, so waiting on a
/// real animation frame would hang. Snapshots force their own paint via afterScreenUpdates instead.
function fontsSettled() {
  return Promise.race([
    document.fonts.ready.then(() => undefined),
    new Promise<void>((resolve) => setTimeout(resolve, 2000)),
  ])
}

const api = {
  async load(
    source: string,
    options: {
      fps?: number
      seed?: number
      width?: number
      height?: number
      durationInFrames?: number
    } = {},
  ) {
    sceneError = null
    seenCandidates.clear()
    currentTimeMs = 0
    fps = options.fps && options.fps > 0 ? options.fps : 30
    sceneConfig = {
      fps,
      width: options.width ?? 0,
      height: options.height ?? 0,
      durationInFrames: options.durationInFrames ?? 0,
    }
    window.__clock.seedRandom(options.seed ?? 0x9e3779b9)
    window.__clock.set(0)

    try {
      if (!compiler) await startTailwind()
      const Scene = evaluate(source)

      root?.unmount()
      const container = document.getElementById("scene")!
      container.innerHTML = ""
      root = createRoot(container, { onUncaughtError: recordError, onCaughtError: recordError })
      flushSync(() => {
        root!.render(<SceneHost Scene={Scene} />)
      })
      flushStyles()
      await fontsSettled()
    } catch (error) {
      recordError(error)
    }
    return this.status()
  },

  seek(ms: number) {
    currentTimeMs = ms
    window.__clock.set(ms)
    try {
      // Covers Motion's WAAPI-accelerated path, CSS animations and CSS transitions in one step.
      for (const animation of document.getAnimations()) {
        animation.pause()
        animation.currentTime = ms
      }
      // Covers Motion's JS frameloop and any rAF-driven scene code.
      window.__clock.flush()
      flushSync(() => {
        for (const listener of timeListeners) listener()
      })
      flushStyles()
    } catch (error) {
      recordError(error)
    }
    return sceneError === null
  },

  status() {
    return { ok: sceneError === null, error: sceneError }
  },
}

window.__motion = api
