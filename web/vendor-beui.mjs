import fs from "node:fs"
import path from "node:path"

const ROOT = path.dirname(new URL(import.meta.url).pathname)
const REGISTRY = "https://beui.dev/r"
const SKIPPED_DEPENDENCIES = new Set(["shiki"])

const registry = await (await fetch(`${REGISTRY}/registry.json`)).json()
const items = registry.items.filter(
  (item) =>
    item.files.some((f) => f.path.startsWith("components/motion/")) &&
    !(item.dependencies ?? []).some((d) => SKIPPED_DEPENDENCIES.has(d))
)

const componentsDir = path.join(ROOT, "src/components/beui")
fs.rmSync(componentsDir, { recursive: true, force: true })
fs.mkdirSync(componentsDir, { recursive: true })

const written = new Map()
const skipped = registry.items.filter((item) => !items.includes(item)).map((item) => item.name)

for (const item of items) {
  const detail = await (await fetch(`${REGISTRY}/${item.name}.json`)).json()
  for (const file of detail.files) {
    let target
    if (file.path.startsWith("components/motion/")) {
      target = path.join(componentsDir, file.path.slice("components/motion/".length))
    } else if (file.path.startsWith("components/agents/")) {
      target = path.join(componentsDir, "agents", file.path.slice("components/agents/".length))
    } else if (file.path === "lib/utils.ts") {
      continue
    } else if (file.path.startsWith("lib/")) {
      target = path.join(ROOT, "src", file.path)
    } else {
      throw new Error(`${item.name}: unexpected file path ${file.path}`)
    }
    const content = file.content
      .replaceAll("@/components/motion/", "@/components/beui/")
      .replaceAll("@/components/agents/", "@/components/beui/agents/")
    const normalized = content.replace(/^\/\/ beui\.dev\/.*\n?/gm, "").replace(/\n+/g, "\n")
    const previous = written.get(target)
    if (previous !== undefined) {
      if (previous !== normalized) throw new Error(`conflicting content for ${target} (item ${item.name})`)
      continue
    }
    fs.mkdirSync(path.dirname(target), { recursive: true })
    fs.writeFileSync(target, content)
    written.set(target, normalized)
  }
}

const components = [...written.keys()].filter((p) => p.startsWith(componentsDir)).length
if (components < 90) throw new Error(`beui vendor looks incomplete (${components} component files)`)
console.log(`vendored ${items.length} items, ${written.size} files (${components} components)`)
console.log(`skipped: ${skipped.join(", ")}`)
