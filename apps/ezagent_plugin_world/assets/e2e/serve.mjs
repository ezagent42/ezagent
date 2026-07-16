import {createReadStream, existsSync, statSync} from "node:fs"
import {createServer} from "node:http"
import {dirname, extname, resolve, sep} from "node:path"
import {fileURLToPath} from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const worldBuild = resolve(here, "../../../ezagent_web/priv/static/assets/world")
const fixtureRoot = resolve(here, "fixtures")
const port = Number(process.env.WORLD_E2E_PORT || 4178)

const contentTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".woff2": "font/woff2",
}

function safePath(root, relative) {
  const path = resolve(root, relative)
  return path === root || path.startsWith(`${root}${sep}`) ? path : null
}

function routePath(url) {
  const pathname = decodeURIComponent(new URL(url, `http://127.0.0.1:${port}`).pathname)

  if (pathname === "/" || pathname === "/harness.html") return resolve(here, "harness.html")
  if (pathname === "/mount-harness.js") return resolve(here, "mount-harness.js")

  if (pathname.startsWith("/assets/world/")) {
    return safePath(worldBuild, pathname.slice("/assets/world/".length))
  }

  if (pathname.startsWith("/fixtures/")) {
    return safePath(fixtureRoot, pathname.slice("/fixtures/".length))
  }

  return null
}

const server = createServer((request, response) => {
  const path = routePath(request.url || "/")

  if (!path || !existsSync(path) || !statSync(path).isFile()) {
    response.writeHead(404, {"content-type": "text/plain; charset=utf-8"})
    response.end("not found")
    return
  }

  response.writeHead(200, {
    "cache-control": "no-store",
    "content-type": contentTypes[extname(path)] || "application/octet-stream",
  })
  createReadStream(path).pipe(response)
})

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`World Tier-1 harness: http://127.0.0.1:${port}\n`)
})

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)))
}
