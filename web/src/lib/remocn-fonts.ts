// The runtime page forbids remote font loads (CSP font-src data:), so scenes authored against
// @remotion/google-fonts resolve to the system stack instead.
export function loadFont() {
  return {
    fontFamily: 'system-ui, -apple-system, "Helvetica Neue", sans-serif',
    waitUntilDone: () => Promise.resolve(),
    fontUrl: "",
    unicodeRanges: {},
  }
}
