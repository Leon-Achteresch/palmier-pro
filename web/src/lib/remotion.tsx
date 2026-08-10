import * as React from "react"
import { ABSOLUTE_FILL_STYLE, interpolate } from "palmier-runtime"

export * from "palmier-runtime"

export function AbsoluteFill({ style, children, ...rest }: React.ComponentProps<"div">) {
  return (
    <div style={{ ...ABSOLUTE_FILL_STYLE, ...style } as React.CSSProperties} {...rest}>
      {children}
    </div>
  )
}

export function Img(props: React.ComponentProps<"img">) {
  return <img {...props} />
}

export function interpolateColors(input: number, inputRange: number[], outputRange: string[]): string {
  const channels = outputRange.map(parseColor)
  const rgba = [0, 1, 2, 3].map((channel) =>
    interpolate(
      input,
      inputRange,
      channels.map((color) => color[channel]),
      { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
    ),
  )
  const [r, g, b, a] = rgba
  return `rgba(${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)}, ${a})`
}

function parseColor(value: string): [number, number, number, number] {
  const hex = value.trim().replace(/^#/, "")
  if (/^[0-9a-f]{3,8}$/i.test(hex) && value.trim().startsWith("#")) {
    const expand = hex.length <= 4 ? hex.split("").map((c) => c + c).join("") : hex
    const int = parseInt(expand.slice(0, 6), 16)
    const alpha = expand.length === 8 ? parseInt(expand.slice(6, 8), 16) / 255 : 1
    return [(int >> 16) & 255, (int >> 8) & 255, int & 255, alpha]
  }
  const parts = value.match(/-?[\d.]+/g)
  if (!parts || parts.length < 3) throw new Error(`interpolateColors cannot parse "${value}"`)
  return [Number(parts[0]), Number(parts[1]), Number(parts[2]), parts[3] === undefined ? 1 : Number(parts[3])]
}

// Palmier drives frames by seek + snapshot rather than Remotion's render-handle protocol, so scenes
// that gate on asset readiness simply proceed.
let nextRenderHandle = 1
export function delayRender() {
  return nextRenderHandle++
}
export function continueRender(_handle: number) {}
export function cancelRender(error: unknown): never {
  throw error instanceof Error ? error : new Error(String(error))
}
