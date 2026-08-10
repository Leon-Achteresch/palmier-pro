export function loadFont() {
  return {
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, "SF Mono", monospace',
    waitUntilDone: () => Promise.resolve(),
    fontUrl: "",
    unicodeRanges: {},
  }
}
