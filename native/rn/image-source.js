export function embeddedImageSource(source) {
  if (source == null) return null
  if (Array.isArray(source)) {
    if (!source.length) return null
    if (source.length > 16 || source.some(item => item == null || Array.isArray(item))) throw new Error("Image candidates must contain 1 to 16 embedded image sources")
    return source.map(embeddedImageSource)
  }
  if (typeof source === "string") source = {uri: source}
  if (typeof source !== "object" || typeof source.uri !== "string" || !source.uri.startsWith("data:image/")) {
    throw new Error("React Native images must be embedded data URLs; bundle the asset with the component")
  }
  return source
}
