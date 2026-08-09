import React from "react"

// Remotion-shaped scene API. Shared verbatim by the web and React Native runtimes: everything here
// is pure React, so only the host element for AbsoluteFill differs between them.

const TimelineContext = React.createContext({ frame: 0 })
const ConfigContext = React.createContext({ fps: 30, width: 1920, height: 1080, durationInFrames: 1 })

export const PalmierInternals = { TimelineContext, ConfigContext }

/** The frame being rendered. A scene is a pure function of this — that is what makes it seekable. */
export function useCurrentFrame() {
  return React.useContext(TimelineContext).frame
}

export function useVideoConfig() {
  return React.useContext(ConfigContext)
}

// MARK: - interpolate

function assertNumber(value, name) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError(`${name} must be a finite number, got ${String(value)}`)
  }
}

function extrapolate(mode, value, min, max) {
  if (mode === "identity") return value
  if (mode === "clamp") return Math.min(Math.max(value, min), max)
  return value
}

export function interpolate(input, inputRange, outputRange, options = {}) {
  assertNumber(input, "input")
  if (!Array.isArray(inputRange) || !Array.isArray(outputRange)) {
    throw new TypeError("interpolate expects inputRange and outputRange arrays")
  }
  if (inputRange.length !== outputRange.length) {
    throw new Error(
      `inputRange (${inputRange.length}) and outputRange (${outputRange.length}) must have the same length`,
    )
  }
  if (inputRange.length < 2) throw new Error("interpolate needs at least two range entries")
  inputRange.forEach((value, index) => {
    assertNumber(value, `inputRange[${index}]`)
    if (index > 0 && value <= inputRange[index - 1]) {
      throw new Error("inputRange must increase monotonically")
    }
  })
  outputRange.forEach((value, index) => assertNumber(value, `outputRange[${index}]`))

  const { extrapolateLeft = "extend", extrapolateRight = "extend", easing } = options

  if (input < inputRange[0]) {
    if (extrapolateLeft === "clamp") return outputRange[0]
    if (extrapolateLeft === "identity") return input
  }
  const last = inputRange.length - 1
  if (input > inputRange[last]) {
    if (extrapolateRight === "clamp") return outputRange[last]
    if (extrapolateRight === "identity") return input
  }

  let segment = 0
  while (segment < last - 1 && input >= inputRange[segment + 1]) segment++

  const inputStart = inputRange[segment]
  const inputEnd = inputRange[segment + 1]
  const outputStart = outputRange[segment]
  const outputEnd = outputRange[segment + 1]

  let progress = (input - inputStart) / (inputEnd - inputStart)
  if (easing) progress = easing(progress)

  const result = outputStart + progress * (outputEnd - outputStart)
  if (input < inputRange[0]) return extrapolate(extrapolateLeft, result, outputRange[0], outputRange[last])
  if (input > inputRange[last]) return extrapolate(extrapolateRight, result, outputRange[0], outputRange[last])
  return result
}

// MARK: - spring

const DEFAULT_SPRING = { damping: 10, mass: 1, stiffness: 100, overshootClamping: false }

function springValue(frame, fps, config) {
  const { damping, mass, stiffness, overshootClamping } = config
  const time = frame / fps
  if (time <= 0) return 0

  const criticalDamping = 2 * Math.sqrt(stiffness * mass)
  const zeta = damping / criticalDamping
  const omega0 = Math.sqrt(stiffness / mass)

  let value
  if (zeta < 1) {
    const omega1 = omega0 * Math.sqrt(1 - zeta * zeta)
    value =
      1 -
      Math.exp(-zeta * omega0 * time) *
        (Math.cos(omega1 * time) + ((zeta * omega0) / omega1) * Math.sin(omega1 * time))
  } else {
    value = 1 - Math.exp(-omega0 * time) * (1 + omega0 * time)
  }
  return overshootClamping ? Math.min(value, 1) : value
}

/** Physical spring evaluated at a frame. Deterministic: no integration state carries between frames. */
export function spring({ frame, fps, config = {}, from = 0, to = 1, durationInFrames, delay = 0 }) {
  assertNumber(frame, "frame")
  assertNumber(fps, "fps")
  if (fps <= 0) throw new Error("fps must be positive")

  const merged = { ...DEFAULT_SPRING, ...config }
  let effective = frame - delay

  if (durationInFrames !== undefined) {
    assertNumber(durationInFrames, "durationInFrames")
    if (durationInFrames <= 0) throw new Error("durationInFrames must be positive")
    const natural = springSettleFrames(fps, merged)
    effective = (effective / durationInFrames) * natural
  }

  return from + springValue(effective, fps, merged) * (to - from)
}

function springSettleFrames(fps, config) {
  for (let frame = 0; frame < fps * 20; frame++) {
    if (Math.abs(1 - springValue(frame, fps, config)) < 0.005) return frame
  }
  return fps * 20
}

// MARK: - Easing

function bezier(x1, y1, x2, y2) {
  const curveX = (t) => 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
  const curveY = (t) => 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
  return (progress) => {
    let low = 0
    let high = 1
    let t = progress
    for (let i = 0; i < 20; i++) {
      const x = curveX(t)
      if (Math.abs(x - progress) < 1e-5) break
      if (x < progress) low = t
      else high = t
      t = (low + high) / 2
    }
    return curveY(t)
  }
}

export const Easing = {
  linear: (t) => t,
  ease: bezier(0.42, 0, 1, 1),
  quad: (t) => t * t,
  cubic: (t) => t * t * t,
  poly: (exponent) => (t) => Math.pow(t, exponent),
  sin: (t) => 1 - Math.cos((t * Math.PI) / 2),
  circle: (t) => 1 - Math.sqrt(1 - t * t),
  exp: (t) => Math.pow(2, 10 * (t - 1)),
  bezier,
  back:
    (overshoot = 1.70158) =>
    (t) =>
      t * t * ((overshoot + 1) * t - overshoot),
  elastic:
    (bounciness = 1) =>
    (t) => {
      const p = bounciness * Math.PI
      return 1 - Math.pow(Math.cos((t * Math.PI) / 2), 3) * Math.cos(t * p)
    },
  bounce: (t) => {
    if (t < 1 / 2.75) return 7.5625 * t * t
    if (t < 2 / 2.75) {
      const shifted = t - 1.5 / 2.75
      return 7.5625 * shifted * shifted + 0.75
    }
    if (t < 2.5 / 2.75) {
      const shifted = t - 2.25 / 2.75
      return 7.5625 * shifted * shifted + 0.9375
    }
    const shifted = t - 2.625 / 2.75
    return 7.5625 * shifted * shifted + 0.984375
  },
  in: (easing) => easing,
  out: (easing) => (t) => 1 - easing(1 - t),
  inOut: (easing) => (t) => (t < 0.5 ? easing(t * 2) / 2 : 1 - easing((1 - t) * 2) / 2),
}

// MARK: - Deterministic random

/** Stable for a given seed across runs and machines, so a bake never changes underneath you. */
export function random(seed) {
  const key = typeof seed === "string" ? hashString(seed) : Math.floor(Number(seed) || 0)
  let state = (key + 0x6d2b79f5) | 0
  state = Math.imul(state ^ (state >>> 15), 1 | state)
  state = (state + Math.imul(state ^ (state >>> 7), 61 | state)) ^ state
  return ((state ^ (state >>> 14)) >>> 0) / 4294967296
}

function hashString(value) {
  let hash = 0
  for (let index = 0; index < value.length; index++) {
    hash = (Math.imul(31, hash) + value.charCodeAt(index)) | 0
  }
  return hash
}

// MARK: - Time-shifting components

export function Sequence({ from = 0, durationInFrames = Infinity, children, name }) {
  const parentFrame = useCurrentFrame()
  const frame = parentFrame - from

  if (frame < 0 || frame >= durationInFrames) return null

  return React.createElement(TimelineContext.Provider, { value: { frame } }, children)
}
Sequence.displayName = "Sequence"

export function Loop({ durationInFrames, times = Infinity, children }) {
  const frame = useCurrentFrame()
  if (!(durationInFrames > 0)) throw new Error("Loop needs a positive durationInFrames")

  const iteration = Math.floor(frame / durationInFrames)
  if (iteration >= times) return null

  return React.createElement(
    TimelineContext.Provider,
    { value: { frame: frame - iteration * durationInFrames } },
    children,
  )
}

export function Freeze({ frame, children }) {
  assertNumber(frame, "frame")
  return React.createElement(TimelineContext.Provider, { value: { frame } }, children)
}

/** Lays children out back to back; each child is a `Series.Sequence` carrying its own length. */
export function Series({ children }) {
  let offset = 0
  const laidOut = React.Children.map(children, (child) => {
    if (!React.isValidElement(child)) return null
    const duration = child.props.durationInFrames
    if (!(duration > 0)) throw new Error("Series.Sequence needs a positive durationInFrames")
    const element = React.createElement(
      Sequence,
      { from: offset, durationInFrames: duration },
      child.props.children,
    )
    offset += duration
    return element
  })
  return React.createElement(React.Fragment, null, laidOut)
}

Series.Sequence = function SeriesSequence({ children }) {
  return React.createElement(React.Fragment, null, children)
}

export const ABSOLUTE_FILL_STYLE = {
  position: "absolute",
  top: 0,
  left: 0,
  right: 0,
  bottom: 0,
  width: "100%",
  height: "100%",
  display: "flex",
  flexDirection: "column",
}
