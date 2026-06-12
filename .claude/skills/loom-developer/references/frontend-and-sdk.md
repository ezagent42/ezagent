# Loom frontend, SDK bridge & data lifecycle

Authoritative design docs (read the one matching your change — they carry the *why*):
- `docs/loom/2026-05-29-frontend-plugin-integration.md` — the dist-only integration model + the 4 build-time adaptations.
- `docs/loom/2026-05-29-loom-sdk-bridge.md` — the postMessage bridge + the v1 SDK.
- `docs/loom/sdk-v2-additions.md` — upload / resource / fetch / tool.
- `docs/loom/2026-06-05-shareable-snapshots-and-fork.md` — publish / snapshot / fork.
- `docs/loom/2026-06-08-loom-data-lifecycle.md` — where every piece of data lives, stage by stage.
- `docs/loom/PRD.md`, `TEMPLATE_DESIGN.md`, `SDK.md` — product + template + SDK background.

(`FRONTEND_DIST_PLAN.md` describes the *predecessor* `studio-mobile`/hello-plugin Vite flow — historical. The current Loom frontend is the Next.js `ai-ui-builder` model below. Don't follow the Vite `dist/`/`5175`/`npm` details from that file for Loom.)

## 1. The big rule: source is NOT in this repo

| | Location | In ezagent repo? | Node needed? |
|---|---|---|---|
| Frontend **source** (Next.js 14, package `ai-ui-builder`) | `C:\Users\ning\Desktop\work\loom` (separate Desktop repo; from WSL: `/mnt/c/Users/ning/Desktop/work/loom`) | ❌ no | yes — build/dev only |
| Frontend **build output** (static export) | `apps/ezagent_plugin_loom/priv/static/loom_ui/` | ✅ vendored | no |
| Backend serving it | `apps/ezagent_plugin_loom/lib/ezagent/web_plug.ex` | ✅ | — (pure Elixir) |

**Decision D5 ("dist-only"):** the ezagent repo holds *only the built artifact*; the frontend source stays in the Desktop repo; integration tweaks are environment switches in that source. The runtime/deploy story is "no Node, just `mix phx.server` feeding the committed static files."

### What this means for you (and for Claude Code)

- **Do NOT hand-edit files under `priv/static/loom_ui/`** to make a frontend change "stick". They are build output — the next `pnpm build` + sync **overwrites** them. The `_next/static/...` filenames are content-hashed and change every build, so any edit you make there is both invisible to source control intent and ephemeral. The *only* legitimate edits to `priv/static/loom_ui/` are the wholesale replacement done by the sync step (§3).
- A real frontend change is made in the Desktop `ai-ui-builder` repo, then rebuilt and synced in.
- If you (Claude Code) are running inside the ezagent repo and asked to "change the Loom UI," and the Desktop source isn't reachable, **say so** — you cannot meaningfully edit the UI from the vendored export. Surface it rather than editing hashed bundles.

## 2. The 4 build-time adaptations (live in the Desktop source, behind `NEXT_PUBLIC_ESR`)

These must stay in the Desktop source and be **environment-switched** so `pnpm dev` still runs standalone and only the ESR-targeted build flips to `/loom`:

1. **`next.config.mjs`** — gated on `process.env.NEXT_PUBLIC_ESR === '1'`. In ESR mode it sets `output: 'export'` + `basePath: '/loom'` + `images: { unoptimized: true }` (no separate `assetPrefix` — `basePath` alone resolves assets at `/loom/_next/...`). Non-ESR build/dev returns `{}` (standalone on `:3000`). (Confirm a build's mode by grepping `priv/static/loom_ui/index.html` for `/loom/_next/`.)
2. **Chat endpoint** — Next Route Handlers don't exist in a static export. The page-gen system prompt moved server-side (it's now the `loomv0` worker, not an HTTP route). `pnpm dev` keeps a local handler for standalone work.
3. **`useChat` hook** — absolute path, `streamProtocol: 'text'` (the backend returns the whole body as one assistant message; DeepSeek replies non-streaming).
4. **`app/page.tsx`** — parse `:workspace` + `:session_id` out of `window.location.pathname` (`/loom/:ws/:sid`) as the per-page state-isolation key.

> Node appears **only** in the frontend repo, **only** at build/dev time. ESR never runs Node and never runs a dev server — it serves the committed static export.

## 3. Build → sync → run

```bash
# In the Desktop frontend repo (NOT ezagent), from WSL:
cd /mnt/c/Users/ning/Desktop/work/loom
rm -rf .next out                           # clean — see WSL note below
NEXT_PUBLIC_ESR=1 npx next build           # static export → out/  (pnpm build also works)

# Sync into the plugin. GUARD the delete (memory feedback-destructive-file-ops-guardrails):
rsync -a --delete \
  out/ \
  /home/ning/ezagent/apps/ezagent_plugin_loom/priv/static/loom_ui/
# (never a bare `rm -rf $VAR/*`; if you must rm, rm a LITERAL path only.)

# Run ESR (pure Elixir, no Node):
cd /home/ning/ezagent
DEEPSEEK_KEY=sk-... LOOM_LLM_BACKEND=deepseek mix phx.server
# open http://localhost:10042/loom/<ws>/<sid>
```

> ⚠️ **Two WSL build traps (verified 2026-06-12):**
> 1. **`node` here is `node.exe`** (`/mnt/c/nvm4w/nodejs`, a Windows binary). WSL does **not** forward shell env vars across the Win boundary unless they're in `WSLENV` — so `NEXT_PUBLIC_ESR=1 npx next build` silently builds **without** ESR (no `output:'export'`, **no `out/`** produced, basePath wrong), yet still prints "✓ Compiled successfully". The flag must reach Next via a file: drop a throwaway **`.env.production`** with `NEXT_PUBLIC_ESR=1` in the source dir (Next loads `.env*` from disk before evaluating `next.config.mjs`), build, then delete it (it's **not** gitignored — leaving it would force ESR on every prod build). Confirm a real ESR build by checking `out/index.html` contains `/loom/_next/`.
> 2. **Always `rm -rf .next out` first.** On the 9p `/mnt/c` mount, file mtimes are unreliable, so Next's incremental cache can reuse a stale module and emit an **identical content-hashed chunk** — your source edit silently doesn't ship.

- A **frontend-only** change = rebuild + sync + hard-refresh the browser. **No backend restart needed** (the static files are served fresh; memory `feedback-warn-before-dev-server-restart`).
- A **backend** change (any `.ex`) needs the ~4.5-min `phx.server` restart — **tell Allen first**.
- Committing the vendored `out/`: the git status will show deleted old hashed chunks + new ones (that's normal per-build churn). **Only commit when asked.**

## 4. The SDK bridge — how the generated page talks to the backend

The AI-generated page runs in a **Sandpack iframe**. It cannot fetch the backend directly (it has no token and would face cross-frame issues). Instead:

```
[Sandpack iframe: AI-generated page]
   uses window.loom.*  (sdk.js — postMessage client, correlation-id RPC)
        │  window.parent.postMessage({id, method, args})
        ▼
[Host page: ai-ui-builder LoomBridge]   ← reads ws/sid from URL
        │  same-origin fetch / EventSource to /loom/api/:ws/:sid/*
        ▼
[EzagentPluginLoom.WebPlug]  → dispatch into session  (+ direct DeepSeek for Stitch/AiSpot)
```

Same-origin means **no CORS** and the token never reaches the sandbox. The host opens one `EventSource` (`/stream`) and re-`postMessage`s frames back into the iframe.

### SDK surface

**v1** (`sdk.js`, per `2026-05-29-loom-sdk-bridge.md`):

| method | backend | shape |
|---|---|---|
| `sendMessage({text})` | `POST /api/:ws/:sid/messages` | → `{ok, id}` |
| `onMessage(cb)` | `GET /api/:ws/:sid/stream` (SSE) | frames: `{id, sender, role, body, refId}` |
| `getHistory()` | `GET /api/:ws/:sid/history` | `[{id, sender, role, body, refId}, ...]` |

**v2** (`docs/loom/sdk-v2-additions.md`):

| method | backend | shape |
|---|---|---|
| `uploadFile(file, opts?)` | `POST /api/:ws/:sid/upload` (multipart) | → `{ok, uri:"resource://uploads/:ws/:name", name, size, mime}` |
| `openResource(uri)` | `GET /api/:ws/:sid/resource?uri=...` | 302 → `/files/:name` |
| `fetch(preset, url, init?)` | `POST /api/:ws/:sid/fetch` | → `{ok, status, headers, body, truncated}` (whitelist presets only) |
| `tool(name, args)` | `POST /api/:ws/:sid/tool` | → `{ok, result}` / `{ok:false, error}` |

Backend handlers all live in `web_plug.ex` (see `backend-map.md` §3). The frontend half of the SDK (`sdk.js`, `LoomBridge`, `PreviewPanel` wiring) lives in the **Desktop** repo — changing the SDK is a two-repo change: backend endpoint here, client in `ai-ui-builder`.

## 5. The four preview-side features

- **Stitch chat** — floating assistant on published/preview pages. `GET/POST /api/:ws/:sid/stitch`. Calls **DeepSeek directly** (not `LLM`). Since the 2026-06-10 refactor it runs as the in-session `loomstitch_<sid>` worker — a team member, but `@`-only so the orchestrator never reaches it (see `backend-map.md` §2 Plane B). Maps NL → a component `DRIVE: {id, action, params}` (applied by the frontend engine, *not* persisted) or a plain reply / `addText` op (appended to `user_schema`). Grounded by `Knowledge.get`. The frontend sends the page's current **capability list** (`caps`) so DeepSeek knows what components it can drive.
- **AiSpot** — click a "✨" hotspot → `POST /api/:ws/:sid/aispot` with the v0-injected local context → a dynamic card. Same `loomstitch` worker (`mode=aispot`), **direct DeepSeek**, also `Knowledge`-grounded.
- **user_schema (the "draggable"/overlay ops)** — `GET/POST /api/:ws/:sid/user-schema`. A per-session **ordered list of immutable ops** (`addText`, `updateState`, …) layered on top of the frozen base page. `POST {op}` appends; `POST {ops}` replaces (used after the host upserts stateful-component ops). The op vocabulary is interpreted by the frontend engine, not the backend.
- **publish / snapshot / fork** — see §6.

## 6. Data lifecycle (`2026-06-08-loom-data-lifecycle.md`)

The invariant: **only the authoring session's `loomv0` worker can change page source.** Every consumer surface gets a frozen base + its own overlay ops.

| stage | what happens | where data goes |
|---|---|---|
| Authoring | user @v0 → page regenerated | orchestrator `:loom_orchestrator` slice `loom_source` (framework-snapshotted) |
| **Publish** (`/publish`) | freeze current source → immutable published Template Class + token | `loom_saved_classes.json` + a live `Module.create`'d class; link `/loom/p/<token>` |
| **Open** (`/p/:token/open`) | mint a NEW no-v0 session per open (`pub_<hex>`) + temp user | new session, blank `user_schema`, blank Stitch |
| **Snapshot** (`/snapshot`) | freeze current page+ops+Stitch convo (copy-on-snapshot) | `loom_snapshots.json` keyed by token; read via `GET /snapshot/:token` (no session) |
| **Fork** (`/p/:token/fork`) | from a snapshot, mint a NEW session: copy frozen page as base, copy ops into `user_schema`, copy convo into Stitch | new no-v0 session; gated by `/whoami` (must be logged in) |

So at any moment: page source = `Render(frozen base) ⊕ Apply(user_schema ops)`. Stitch and AiSpot enhance the *experience* but never the *source*.
