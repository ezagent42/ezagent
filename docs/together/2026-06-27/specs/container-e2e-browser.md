# Container-reachable E2E browser — a chromium sidecar for the in-container dev loop

> **Status:** Spec (small, bounded — one sidecar service + endpoint config). 2026-06-27.
> **Branch:** `docs/container-e2e-browser-spec` (off `origin/main`; do NOT merge).
> **Author:** Claude (agent dev), for the lead.
> **Scope:** Restore the `cc develops → agent-browser drives Chrome → E2E
> screenshot/verify` loop **for an agent (cc) running INSIDE the ezagent
> container**, after ezagent deploys into Docker. Single-container topology (a)
> stays; this adds **one** internal-only browser service + an endpoint config.
> Operator-only trust model unchanged.
> **Non-goal:** no topology rework, no per-agent containers, no production
> browser capability, no platform.

**Reads this builds on (`git show origin/main:<path>` / `origin/docs/docker-agents-impact:<path>`):**
- `docs/together/2026-06-27/notes/docker-deploy-agents-impact.md` (OQ-3 "browser
  sidecar", §2.4) — established that topology (a) is correct, agent-browser is a
  **dev/DoD verification tool** (no production agent drives a browser), and flagged
  the browser-sidecar as the one open item if a role needs a real browser.
- `docs/superpowers/specs/2026-06-25-deploy-flow-design.md` — the decided 3-channel
  ladder (`nightly/beta/stable`), "build once, promote the artifact."
- `docker/docker-compose.prod.yml`, `docker/docker-compose.yml` (parameterized
  channel stack), `docker/docker-compose.disp.yml` (disposable E2E stack, :10044),
  `docker/Dockerfile.prod`.
- `docs/e2e/auto/lib.sh`, `docs/e2e/auto/run.sh` — the actual agent-browser runbook.

---

## 0. TL;DR

1. **The premise that makes this needed (and the cheaper thing it rejects).** Today
   the dev loop is **host-driven**: agent-browser launches Chrome on the macOS host
   and drives the app at the Tailscale IP. After containerization the *app* is in a
   container but agent-browser still runs on the host — **that keeps working with
   zero new containers** (just point at the published port). A sidecar is needed
   **only because the lead wants cc to run E2E from INSIDE the container** (so the
   in-container agent can finish dev + self-verify). That single requirement, not
   Docker itself, is what this spec serves. The host-driven path remains the
   dev-mode default; the sidecar is the deploy/in-container path.

2. **Verified connection model — the fix is "point at an endpoint," not a rewrite.**
   agent-browser already supports **two** modes: (i) *launch* a local Chrome
   (`open`, default), and (ii) *connect* to a remote CDP endpoint
   (`connect <port|url>`, accepting `ws://`/`wss://`, explicitly documented for
   "remote browser service"), plus a first-class `AGENT_BROWSER_PROVIDER=browserless`
   provider mode. **No launch→connect code change is required** — the connect
   capability ships in the CLI.

3. **The actual gap is the IMAGE, not the CLI's ability.** `Dockerfile.prod` bakes
   `claude/codex/uv/node/git` only — **no `agent-browser` binary and no Chromium**.
   For in-container cc to run E2E, the **agent-browser binary must be added to the
   ezagent image** (Chrome stays OUT — it lives in the sidecar).

4. **The sidecar = one headless-chromium service** (`ghcr.io/browserless/chromium`),
   internal-network-only (no `ports:`), token-authed CDP at `ws://chromium:3000`,
   added **only to the E2E-capable stacks** (disposable + dev; optionally beta for
   smoke) — **never** public stable/prod, which only run health checks.

5. **Artifacts come back over CDP** (base64 screenshot/pdf/snapshot → agent-browser
   writes them to the **ezagent** container's filesystem, the persistent
   `evidence/` dir) — **no shared volume** between sidecar and ezagent. Clean
   boundary, not a gap.

---

## 1. Verified connection model (DO #1 — the discriminator)

> **Method:** read the installed agent-browser tooling directly
> (`/Users/h2oslabs/.claude/plugins/marketplaces/agent-browser/{README.md,AGENTS.md}`,
> the compiled-CLI `--help` and `connect --help` output). agent-browser's daemon is
> a compiled Rust binary (`cli/src/native/` — daemon/actions/browser/CDP client);
> it is **not** vendored in `esr-ng`, so the spec is written against the CLI's
> documented contract, which is authoritative.

agent-browser has **two browser-acquisition modes**:

| Mode | Command | What it does |
|---|---|---|
| **Launch (local)** | `agent-browser open [url]` (default) | Spawns a local Chrome (Chrome-for-Testing, installed via `agent-browser install`). **Needs Chrome on the same host.** |
| **Connect (remote CDP)** | `agent-browser connect <port\|url>` / `--cdp <port>` / `-p browserless` | Attaches to an **already-running** browser over the Chrome DevTools Protocol. **Needs only network reach to a CDP endpoint.** |

`connect --help` (verbatim contract):

```
Usage: agent-browser connect <port|url>
Connects to a running browser instance via Chrome DevTools Protocol (CDP).
This allows controlling browsers, Electron apps, or remote browser services.
Supported URL formats:
  - Port number: 9222 (connects to http://localhost:9222)
  - WebSocket URL: ws://localhost:9222/devtools/browser/...
  - Remote service: wss://remote-browser.example.com/cdp?token=...
```

Plus a built-in **provider** abstraction (`AGENT_BROWSER_PROVIDER`, values include
`browserless`, `browserbase`, `kernel`, `agentcore`, …). For self-hosted
browserless: `AGENT_BROWSER_PROVIDER=browserless` + `BROWSERLESS_API_URL=...` makes
the ordinary `open` calls connect to that service **instead of** launching local
Chrome — "All commands work identically" (README §Browserless).

### Correcting the framing

The task framing said "agent-browser drives a REMOTE browser at `100.64.0.27`."
That is **imprecise**. The evidence (`docker/README.md`, `docs/e2e/auto/lib.sh`):
- the **browser** today is **local host Chrome** (the runbook calls
  `agent-browser open …` — launch mode);
- `100.64.0.27` is the Tailscale IP of the **app under test**, not the browser.

So today: **browser = host-local (launch), app = remote (Tailscale)**. This matters:
the in-container fix is to flip the **browser** from launch→connect (config only,
capability already present), while the app becomes an internal compose hostname.

**Conclusion (DO #1):** the fix is the **easy path** — "point agent-browser at a
network CDP endpoint" — *not* a launch→connect code change. The one thing that is
genuinely net-new is **shipping the agent-browser binary in the image** (§4).

---

## 2. The chromium sidecar (DO #2)

### 2.1 Options evaluated

| Option | CDP endpoint | Auth | Host-header / origin | Lifecycle / stability | Image size | Verdict |
|---|---|---|---|---|---|---|
| **Hand-rolled** `chromium --headless --remote-debugging-port=9222` (e.g. on a `debian`+`chromium` base) | raw `/json/version` → `webSocketDebuggerUrl` | **none** (unauthenticated CDP — anyone on the net controls the browser) | **binds 127.0.0.1**; CDP enforces a **Host-header allowlist** on `/json/*` → rejects docker DNS names; needs `--remote-debugging-address=0.0.0.0 --remote-allow-origins=*` | **none** — a crashed/zombie Chrome stays dead; no queue, no recycle; the `webSocketDebuggerUrl` **changes every launch** (must be re-discovered each run) | small (~400-700 MB) but you maintain the Chrome+deps install | ❌ you re-implement auth, lifecycle, origin-handling badly |
| **`ghcr.io/browserless/chromium`** (browserless v2) | **stable** `ws://chromium:3000?token=…` (managed) | **`TOKEN` env** (token-authed) | binds per `HOST`/`PORT`; CORS configurable; designed for cross-host CDP | managed Chrome **lifecycle + crash recovery + concurrency/queue + per-session timeout** (`CONCURRENT`/`QUEUED`/`TIMEOUT`) | ~1-2 GB (Chrome + Node service) | ✅ **recommended** |

### 2.2 Recommendation: `ghcr.io/browserless/chromium`

The deciding trade is **the CDP gotcha**, not size:

- **Stable, token-authed endpoint.** `ws://chromium:3000?token=<secret>` is fixed
  for the service's life — the runbook can hardcode it. Raw Chrome hands you a
  per-launch `webSocketDebuggerUrl` you must re-fetch from `/json/version` every
  run, and the Host-header allowlist actively rejects the docker service name
  (you'd have to connect by container IP or fight `--remote-allow-origins`).
- **Managed lifecycle.** browserless restarts/recycles Chrome on crash and bounds
  it with `CONCURRENT`/`QUEUED`/`TIMEOUT` — exactly the stability the E2E loop needs
  for unattended runs. Raw Chrome gives you a single process that, once wedged,
  wedges the whole loop.
- **Auth by default.** `TOKEN` gates the CDP endpoint — raw Chrome's remote-debug
  port is **unauthenticated** (the README explicitly warns "any local process can
  connect").
- **Size is irrelevant here** — the sidecar lives **only** in the E2E/dev stacks,
  never in public prod, so ~1-2 GB never ships to production.

> **CDP version pinning (verify-at-implementation):** pin a concrete tag, not
> `:latest`, so the Chrome/CDP revision is reproducible across the channel ladder
> (build-once-promote). The browserless image bundles a matched Chrome+CDP, so
> there is no agent-browser↔Chrome CDP skew to manage **as long as the tag is
> pinned**. **Action:** confirm the current pinned tag for
> `ghcr.io/browserless/chromium` (v2 line) at implementation time — do not hardcode
> a tag from this spec.
>
> **Provider-mode vs generic-connect skew (open question):** agent-browser's
> `-p browserless` provider was written against the browserless **cloud Sessions
> API**; a **self-hosted** browserless may differ in the session-create handshake.
> If provider-mode misbehaves against the self-hosted image, fall back to the
> **generic `connect "ws://chromium:3000?token=…"`** path, which speaks plain CDP
> and is version-robust. §3 recommends generic-connect as the **default**.

---

## 3. How agent-browser is pointed at it (DO #3)

### 3.1 The image change (the actual gap)

`Dockerfile.prod` (runtime stage) installs `claude/codex/uv/node/git` but **no
agent-browser and no Chrome**. Add the **agent-browser binary** (and **only** the
binary — `--engine chrome` is never used in-container; we always `connect`):

```dockerfile
# runtime stage, alongside the existing claude/codex install:
#   agent-browser CLI (CDP client only — NO Chrome; the browser is the sidecar).
#   pin a concrete version; do NOT run `agent-browser install` (that pulls Chrome).
RUN <install agent-browser binary, pinned version>     # e.g. the prebuilt release
```

> Keep Chrome **out** of the image (the note §2.4 is right: no production agent
> drives a browser). The image gets the *client*; the *browser* is the sidecar.
> This is the single line whose absence would make the sidecar uncallable.

### 3.2 The two modes (dev vs deploy) — one endpoint var

Introduce **one** env knob the runbook honors. The runbook (`docs/e2e/auto/lib.sh`)
currently does `agent-browser open …`; make its `ab_open`/`open` wrapper
**conditional on an endpoint var**:

| Mode | Where agent-browser runs | Browser | How pointed |
|---|---|---|---|
| **dev (host-driven)** — default today | macOS host | local host Chrome (launch) | **no endpoint var set** → `agent-browser open` launches local Chrome; app at `http://world.localhost:10042` (or Tailscale IP). **Unchanged.** |
| **deploy / in-container** — this spec | inside the **ezagent** container | the **chromium sidecar** (connect) | `E2E_BROWSER_CDP=ws://chromium:3000?token=$BROWSERLESS_TOKEN` set on the `ezagent` service → runbook runs `agent-browser connect "$E2E_BROWSER_CDP"` once at start, then drives the app at the **internal** URL `http://ezagent:10042` (or `http://world.localhost:10042` resolving in-container). |

Concretely, the only runbook edit is the connection bootstrap (one place):

```bash
# lib.sh — bootstrap the browser session once:
if [ -n "${E2E_BROWSER_CDP:-}" ]; then
  agent-browser connect "$E2E_BROWSER_CDP"   # deploy/in-container: attach to sidecar
fi
# else: dev/host — ab_open's `agent-browser open` launches local Chrome (today's path)
```

Everything downstream (`ab_open`/`ab_click`/`ab_shot` …) is unchanged: once a
session is connected, `open <url>` navigates the **already-attached** browser.

> **Optional cleaner variant (verify first):** instead of the explicit `connect`,
> set on the ezagent service `AGENT_BROWSER_PROVIDER=browserless`,
> `BROWSERLESS_API_URL=http://chromium:3000`, `BROWSERLESS_API_KEY=$TOKEN` — then
> the existing `agent-browser open` calls transparently use the sidecar with **zero
> runbook edits**. Adopt this **only if** it is verified against the self-hosted
> image (see §2.2 skew note); otherwise use the generic `connect` above, which is
> the recommended default.

### 3.3 The compose change — ONE service, in the E2E stacks

Per memory + the deploy-flow design, **E2E runs on the disposable/dev stacks**, not
public stable. Add **one** `chromium` service to the stacks that actually run
agent-browser — `docker-compose.disp.yml` (the disposable E2E stack, :10044) and
`docker-compose.dev.yml`; optionally beta for smoke. **Not** stable/prod.

```yaml
# add to docker-compose.disp.yml (and dev); NOT prod/stable:
  chromium:
    image: ghcr.io/browserless/chromium:<pinned-tag>   # verify tag at impl
    restart: unless-stopped
    environment:
      TOKEN: ${BROWSERLESS_TOKEN:?set BROWSERLESS_TOKEN}   # gitignored secret
      HOST: "0.0.0.0"            # bind so the ezagent sibling can reach it
      PORT: "3000"
      CONCURRENT: "2"
      TIMEOUT: "120000"
      HEALTH: "true"
    # DELIBERATELY no `ports:` → reachable ONLY on the compose network as
    # chromium:3000, never from host or LAN (mirrors the mihomo internal-only rule).
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:3000/?token=$${TOKEN} >/dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 15s
    # NO egress proxy: the sidecar only renders operator-authored UI served by the
    # app on the internal network; it never needs to reach the internet. Egress-isolate.

# on the ezagent service of the SAME stack, add:
    environment:
      E2E_BROWSER_CDP: "ws://chromium:3000?token=${BROWSERLESS_TOKEN}"
      # so cc's runbook attaches to the sidecar; see §3.2.
    depends_on:
      chromium:
        condition: service_healthy
```

> This is the whole topology delta: **one service + two env lines**, in the
> non-production stacks only. Topology (a) is otherwise untouched.

### 3.4 The check_origin gotcha (silent-failure trap — DO #3 correctness)

In-container, the browser navigates to the app by **internal** origin
(`http://ezagent:10042` or `http://chromium`-side resolution of the app host). The
Phoenix endpoint's `check_origin` / `EZAGENT_EXTRA_CHECK_ORIGINS` currently lists
only `100.64.0.27`/`localhost` origins (see `docker-compose.prod.yml:111`,
`docker-compose.disp.yml`). If the in-container navigation origin is **not** in that
allowlist, the LiveView/React WebSocket handshake is **rejected** and E2E fails with
a blank page — a confusing silent failure. **Action:** add the internal app origin
the in-container runbook uses to `EZAGENT_EXTRA_CHECK_ORIGINS` on the ezagent
service of the E2E stack (e.g. `http://world.localhost:10044`, `http://ezagent:10042`
— whichever `BASE_URL` the in-container runbook targets).

---

## 4. Security (DO #4)

| Concern | This spec |
|---|---|
| **Public ingress** | The `chromium` service has **no `ports:` mapping** → reachable only on the compose network (`chromium:3000`), never from host/LAN/internet. Same internal-only rule as the `mihomo` proxy. |
| **CDP auth** | `TOKEN` env gates the CDP endpoint (raw Chrome's debug port would be unauthenticated). Token is a gitignored secret (`BROWSERLESS_TOKEN` in `docker/.env.<channel>` / `secrets-*`), never committed — consistent with the existing secret pattern. |
| **Navigation scope** | Optionally pin the sidecar / runbook to the internal app origin via agent-browser `--allowed-domains` so the E2E browser can only reach the app under test. |
| **Egress** | The sidecar **needs no internet egress** (the app bundles its own assets: LV-SSR shell + React/shadcn rendered from `priv/`). So it is **not** wired to the mihomo proxy — egress-isolated. Smaller attack surface. |
| **Artifact egress (how screenshots get back)** | `screenshot`/`pdf`/`snapshot` return as **base64 over the CDP WebSocket**; agent-browser (running in the **ezagent** container) writes them to **its own** filesystem — the persistent `docs/e2e/.../evidence/` dir, exactly where evidence lands today. **No shared volume** between the sidecar and ezagent; the only data crossing the boundary is the CDP stream. The operator reads evidence from the ezagent volume as now. |
| **Untrusted-author surface** | **None introduced.** The browser only ever renders **operator-authored** UI (the app the operators build) driven by **operator-authored** E2E scripts. No non-operator code reaches the browser. Consistent with the operator-only trust model (note §4 / py-agent §5 "posture A"): no new trust boundary, so no isolation work triggered. |

---

## 5. Does it preserve the in-container dev-E2E loop? (the completion gate)

The loop is preserved iff, **inside the ezagent container**, cc can run the existing
runbook and get evidence back. Concretely, after this spec:

1. `agent-browser` binary present in image (§3.1) — cc can invoke it. ✔ (was the gap)
2. `E2E_BROWSER_CDP` set → runbook `connect`s to `chromium:3000` (§3.2). ✔
3. `chromium` sidecar healthy on the compose net, token-authed, no public port
   (§3.3). ✔
4. App origin in `check_origin` allowlist → LV/React WS handshake succeeds (§3.4). ✔
5. `agent-browser open http://<internal-app>` navigates the sidecar; `click/fill/
   screenshot` work unchanged; evidence written to the ezagent volume (§4). ✔
6. Operator reads `evidence/*.png` from the ezagent volume as today. ✔

Dev-mode (host) is **unchanged** (no endpoint var → launch local Chrome). The loop
works in **both** modes from one runbook.

---

## 6. Open questions for the lead

1. **agent-browser binary install in `Dockerfile.prod`** — what is the canonical
   pinned-install method (prebuilt release download vs `pnpm add -g
   @agent-browser/cli` equivalent)? Must NOT trigger `agent-browser install`
   (that pulls Chrome, which we deliberately exclude). (Blocking for §3.1.)
2. **Provider-mode vs generic-connect** against the **self-hosted** browserless
   image — verify whether `AGENT_BROWSER_PROVIDER=browserless` +
   `BROWSERLESS_API_URL` works zero-edit, or whether the self-hosted Sessions-API
   handshake differs (then use generic `connect`, the recommended default). §2.2.
3. **Pinned `ghcr.io/browserless/chromium` tag** for the v2 line (reproducible
   across the build-once-promote ladder). §2.2.
4. **Which stacks** carry the sidecar — disposable + dev only, or also beta for
   smoke? (Stable/prod: never — health-check only.) §3.3.
5. **In-container `BASE_URL`** the runbook should target (`http://ezagent:10042`
   vs `http://world.localhost:10044`) — decides the exact
   `EZAGENT_EXTRA_CHECK_ORIGINS` entry to add. §3.4.

---

## 7. Sources

In-repo (`git show origin/main:<path>` unless noted):
- `docs/together/2026-06-27/notes/docker-deploy-agents-impact.md` (`origin/docs/docker-agents-impact`) — §2.4, OQ-3.
- `docs/superpowers/specs/2026-06-25-deploy-flow-design.md`.
- `docker/Dockerfile.prod` (runtime stage — confirms no agent-browser, no Chrome).
- `docker/docker-compose.prod.yml`, `docker/docker-compose.yml`,
  `docker/docker-compose.disp.yml`, `docker/docker-compose.dev.yml`.
- `docs/e2e/auto/lib.sh`, `docs/e2e/auto/run.sh` (confirms `agent-browser open` =
  launch mode; `BASE_URL` is the app, not the browser).
- `docker/README.md` (confirms `100.64.0.27` = app's Tailscale IP).

External (verified this session):
- agent-browser CLI `--help` / `connect --help` (installed v at
  `~/.claude/plugins/marketplaces/agent-browser`) — `connect <port|url>`, `--cdp`,
  `AGENT_BROWSER_PROVIDER`, Browserless provider.
- `ghcr.io/browserless/chromium` — `TOKEN`/`HOST`/`PORT`/`CONCURRENT`/`TIMEOUT` env,
  `ws://host:3000` CDP endpoint (browserless docs via Context7, `/browserless/browserless`).
