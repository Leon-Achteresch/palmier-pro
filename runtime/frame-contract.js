export const frameOnlyAPIs = ["setTimeout", "setInterval", "requestAnimationFrame", "fetch", "XMLHttpRequest", "WebSocket"]
export function unsupportedFrameAPI(name) {
  return function () { throw new Error(`${name} is not supported in a frame-driven component; expose controlled props or useCurrentFrame`) }
}
export function sourceFactory(code, parameters) {
  return new Function(...parameters, ...frameOnlyAPIs, code)
}
export function runSource(factory, arguments_) {
  return factory(...arguments_, ...frameOnlyAPIs.map(unsupportedFrameAPI))
}
