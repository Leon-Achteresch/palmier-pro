import { defineConfig, type Plugin } from "vite"
import react from "@vitejs/plugin-react"
import { viteSingleFile } from "vite-plugin-singlefile"
import path from "node:path"
import fs from "node:fs"

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
  plugins: [react(), viteSingleFile(), classicScript()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
      // Shared verbatim with the React Native runtime so both speak the same scene API.
      "palmier-runtime": path.resolve(__dirname, "../runtime/palmier.js"),
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
