import {defineConfig} from "vite"
import react from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"

export default defineConfig({
  plugins: [react(), tailwindcss()],
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
