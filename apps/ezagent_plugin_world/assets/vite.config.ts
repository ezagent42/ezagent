import {fileURLToPath, URL} from "node:url"
import {defineConfig} from "vite"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: [
      {find: /^react$/, replacement: fileURLToPath(new URL("./node_modules/react/index.js", import.meta.url))},
      {find: /^react\/(.*)$/, replacement: fileURLToPath(new URL("./node_modules/react", import.meta.url)) + "/$1"},
      {find: /^react-dom$/, replacement: fileURLToPath(new URL("./node_modules/react-dom/index.js", import.meta.url))},
      {find: /^react-dom\/(.*)$/, replacement: fileURLToPath(new URL("./node_modules/react-dom", import.meta.url)) + "/$1"},
      {find: /^lucide-react$/, replacement: fileURLToPath(new URL("./node_modules/lucide-react/dist/cjs/lucide-react.js", import.meta.url))},
      {find: "@excalidraw/excalidraw/index.css", replacement: fileURLToPath(new URL("./node_modules/@excalidraw/excalidraw/dist/prod/index.css", import.meta.url))},
      {find: /^@excalidraw\/excalidraw$/, replacement: fileURLToPath(new URL("./node_modules/@excalidraw/excalidraw/dist/prod/index.js", import.meta.url))},
      {find: "@xyflow/react/dist/style.css", replacement: fileURLToPath(new URL("./node_modules/@xyflow/react/dist/style.css", import.meta.url))},
      {find: /^@xyflow\/react$/, replacement: fileURLToPath(new URL("./node_modules/@xyflow/react/dist/esm/index.js", import.meta.url))},
      {find: /^dagre$/, replacement: fileURLToPath(new URL("./node_modules/dagre/index.js", import.meta.url))},
    ],
  },
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
