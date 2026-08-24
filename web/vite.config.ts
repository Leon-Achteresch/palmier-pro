import { defineConfig, type Plugin } from "vite"
import react from "@vitejs/plugin-react"
import { viteSingleFile } from "vite-plugin-singlefile"
import path from "node:path"
import fs from "node:fs"

/// The scene catalog the agent reads before authoring: module path to the components it exports.
function componentCatalog(): Plugin {
  const output = path.resolve(__dirname, "../Sources/PalmierPro/Resources/MotionRuntime/components.json")
  const libraries = [
    { dir: path.resolve(__dirname, "./src/components/remocn"), prefix: "@/components/remocn", minimum: 100 },
    { dir: path.resolve(__dirname, "./src/components/beui"), prefix: "@/components/beui", minimum: 90 },
  ]
  return {
    name: "palmier-component-catalog",
    enforce: "post",
    closeBundle() {
      const catalog: Record<string, string[]> = {}
      for (const { dir, prefix, minimum } of libraries) {
        let modules = 0
        for (const file of fs.readdirSync(dir, { recursive: true }).map(String).sort()) {
          if (!file.endsWith(".tsx")) continue
          const code = fs.readFileSync(path.join(dir, file), "utf8")
          const exports = [...code.matchAll(/^export (?:function|const) ([A-Z]\w*)/gm)].map((match) => match[1])
          if (exports.length === 0) continue
          catalog[`${prefix}/${file.replace(/\.tsx$/, "").replace(/\/index$/, "")}`] = exports
          modules += 1
        }
        if (modules < minimum) {
          throw new Error(`${prefix} catalog looks incomplete (${modules} modules)`)
        }
      }
      fs.writeFileSync(output, JSON.stringify(catalog, null, 2))
    },
  }
}

/// WebKit refuses module scripts on an opaque origin, and the runtime is loaded via
/// loadHTMLString(baseURL: nil). Rewrite to a classic script once everything is inlined.
function classicScript(): Plugin {
  const output = path.resolve(__dirname, "../Sources/PalmierPro/Resources/MotionRuntime/index.html")
  return {
    name: "palmier-classic-script",
    enforce: "post",
    closeBundle() {
      const html = fs.readFileSync(output, "utf8").replace(/<script\s+type="module"[^>]*>/g, "<script>")
      if (/<script[^>]*\ssrc=/.test(html)) {
        throw new Error("runtime was not inlined into a single file")
      }
      if (html.length < 500_000) {
        throw new Error(`runtime looks truncated (${html.length} bytes) — the bundle was dropped`)
      }
      // The inlined scripts are the whole product; a silently mangled one only shows up as a
      // blank render inside WKWebView, so parse every one of them here instead.
      const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)]
      if (scripts.length < 2) throw new Error(`expected clock + bundle scripts, found ${scripts.length}`)
      for (const [index, match] of scripts.entries()) {
        try {
          new Function(match[1])
        } catch (error) {
          throw new Error(`inlined script #${index} does not parse: ${(error as Error).message}`)
        }
      }
      fs.writeFileSync(output, html)
    },
  }
}

export default defineConfig({
  plugins: [react(), viteSingleFile(), classicScript(), componentCatalog()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
      // Shared verbatim with the React Native runtime so both speak the same scene API.
      "palmier-runtime": path.resolve(__dirname, "../runtime/palmier.js"),
      // remocn components are authored against Remotion's API, which palmier.js already implements.
      remotion: path.resolve(__dirname, "./src/lib/remotion.tsx"),
      // The shared file lives outside this root, so it cannot resolve React on its own.
      react: path.resolve(__dirname, "node_modules/react"),
    },
  },
  define: { "process.env.NODE_ENV": '"production"' },
  build: {
    outDir: path.resolve(__dirname, "../Sources/PalmierPro/Resources/MotionRuntime"),
    emptyOutDir: true,
    target: "safari18",
    cssCodeSplit: false,
    assetsInlineLimit: 100_000_000,
    chunkSizeWarningLimit: 8000,
    rollupOptions: {
      output: { format: "iife", inlineDynamicImports: true },
    },
  },
})
