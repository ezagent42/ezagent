import {defineConfig} from "vite"
import react from "@vitejs/plugin-react"

// Mirrors ezagent_plugin_world's island build: a single-file ES-module library
// that the `HelloRenderer` phx-hook dynamically imports and calls `mountHello`
// on. Built to ezagent_web's static assets so it is served at
// `/assets/hello/main.js`. In dev a Vite server (distinct port) serves it with
// HMR; config wires `hello_module_url` to one or the other.
export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    port: Number(process.env.HELLO_VITE_PORT || 5174),
    strictPort: true,
    cors: true,
    hmr: {host: "localhost", protocol: "ws"},
  },
  build: {
    outDir: "../../ezagent_web/priv/static/assets/hello",
    emptyOutDir: true,
    sourcemap: true,
    lib: {
      entry: "src/main.tsx",
      formats: ["es"],
      fileName: () => "main.js",
      cssFileName: "hello",
    },
    rollupOptions: {
      output: {assetFileNames: "hello.[ext]"},
    },
  },
})
