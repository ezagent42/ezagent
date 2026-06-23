import {defineConfig} from "vite"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // The world bundle is served as an ESM module straight to the browser via a
  // LiveView hook (config.exs world_module_url "/assets/world/main.js"), NOT
  // through a consuming bundler. Vite's `lib` build leaves `process.env.NODE_ENV`
  // un-replaced (it assumes the consumer defines it), so the React UMD shim's
  // `process.env.NODE_ENV` reference throws `process is not defined` and the
  // island never mounts off the static path. Replace it at build time.
  define: {
    "process.env.NODE_ENV": JSON.stringify("production"),
  },
  server: {
    host: "0.0.0.0",
    port: Number(process.env.WORLD_VITE_PORT || 5173),
    strictPort: true,
    cors: true,
    hmr: {
      host: "localhost",
      protocol: "ws",
    },
  },
  build: {
    outDir: "../../ezagent_web/priv/static/assets/world",
    emptyOutDir: true,
    sourcemap: true,
    lib: {
      entry: "src/main.tsx",
      formats: ["es"],
      fileName: () => "main.js",
      cssFileName: "world",
    },
    rollupOptions: {
      output: {
        assetFileNames: "world.[ext]",
      },
    },
  },
})
