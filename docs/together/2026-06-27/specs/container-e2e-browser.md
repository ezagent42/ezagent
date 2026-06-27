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

3. **The actual gap is the IMAGE, not the CLI's ability.** Both runtime images bake
   `claude/codex/uv/node/git` only — **no `agent-browser` binary and no Chromium**.
   The E2E stacks build **`Dockerfile.dev`** (not `Dockerfile.prod`), so the
   **agent-browser binary must be added to `Dockerfile.dev`** (Chrome stays OUT —
   it lives in the sidecar). This is the one change that makes the sidecar callable.

4. **The sidecar = one headless-chromium service** (`ghcr.io/browserless/chromium`),
   on an **`internal: true`** docker network with ezagent (no `ports:`, no internet
   egress), token-authed CDP at `ws://chromium:3000`, added **only to the
   E2E-capable stacks** (disposable + dev; beta only behind `profiles: [e2e]`) —
   **never** the shared/public stable/prod compose, which only run health checks.

5. **Artifacts come back over CDP** (base64 screenshot/pdf/snapshot → agent-browser
   writes them to the **ezagent** container's filesystem) — **no shared volume**
   between sidecar and ezagent. One caveat: point `EVID_DIR` at the persistent
   `/data` volume so evidence survives container recreate (today's default lands
   under container-local `/app`).

6. **Honest delta:** one service + a few env lines (`E2E_BROWSER_CDP`, `BASE_URL`,
   `EVID_DIR`, `NO_PROXY`, `EZAGENT_EXTRA_CHECK_ORIGINS`) + one internal network, in
   the **dev/disp** stacks only. Topology (a) is otherwise untouched. Dev-mode
   (host Chrome) stays the default when those vars are unset.

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
| **Hand-rolled** `chromium --headless --remote-debugging-port=9222` (e.g. on a `debian`+`chromium` base) | raw `/json/version` → `webSocketDebuggerUrl` | **none** (unauthenticated CDP — anyone on the net controls the browser) | **binds 127.0.0.1** → needs `--remote-debugging-address=0.0.0.0` to be reachable by a sibling; CDP also enforces a **Host-header allowlist** on the `/json/*` HTTP endpoints that **rejects docker DNS names** (you must connect by container IP, not `chromium`), and a separate **WebSocket Origin** check governed by `--remote-allow-origins` — two distinct controls you must get right | **none** — a crashed/zombie Chrome stays dead; no queue, no recycle; the `webSocketDebuggerUrl` **changes every launch** (must be re-discovered each run) | small (~400-700 MB) but you maintain the Chrome+deps install | ❌ you re-implement auth, lifecycle, origin/host-handling badly |
| **`ghcr.io/browserless/chromium`** (browserless v2) | **stable** `ws://chromium:3000?token=…` (managed) | **`TOKEN` env** (token-authed) | binds per `HOST`/`PORT`; CORS configurable; designed for cross-host CDP | managed Chrome **lifecycle + crash recovery + concurrency/queue + per-session timeout** (`CONCURRENT`/`QUEUED`/`TIMEOUT`) | ~1-2 GB (Chrome + Node service) | ✅ **recommended** |

### 2.2 Recommendation: `ghcr.io/browserless/chromium`

The deciding trade is **the CDP gotcha**, not size:

- **Stable, token-authed endpoint.** `ws://chromium:3000?token=<secret>` is fixed
  for the service's life — the runbook can hardcode it. Raw Chrome hands you a
  per-launch `webSocketDebuggerUrl` you must re-fetch from `/json/version` every
  run, and its `/json/*` Host-header allowlist rejects the docker service name
  (you'd have to connect by container IP). browserless terminates CDP behind its
  own HTTP service, so the docker-DNS `chromium:3000` endpoint Just Works.
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

### 3.1 The image change (the actual gap) — **`Dockerfile.dev`, not just prod**

Both runtime images bake `claude/codex/uv/node/git` but **no agent-browser and no
Chrome**. **Crucially, the E2E stacks that this spec serves build
`docker/Dockerfile.dev`, NOT `Dockerfile.prod`:** `docker-compose.disp.yml`
(disposable, :10044) and `docker-compose.dev.yml` both set
`dockerfile: docker/Dockerfile.dev` (line 12). So the agent-browser binary must be
added to **`Dockerfile.dev`** (the E2E images); if a stable/beta in-container smoke
ever needs it, add to `Dockerfile.prod` too — but the in-container dev-E2E loop the
lead asked for runs on the **dev/disp** images.

Add the **agent-browser binary** (and **only** the binary — `--engine chrome` is
never used in-container; we always `connect`):

```dockerfile
# Dockerfile.dev, alongside the existing claude/codex install (line ~29):
#   agent-browser CLI (CDP client only — NO Chrome; the browser is the sidecar).
#   pin a concrete version; do NOT run `agent-browser install` (that pulls Chrome).
RUN <install agent-browser binary, pinned version>     # e.g. the prebuilt release
```

> Keep Chrome **out** of the image (the note §2.4 is right: no production agent
> drives a browser). The image gets the *client*; the *browser* is the sidecar.
> This is the single change whose absence would make the sidecar uncallable —
> and it must land in **`Dockerfile.dev`**, the image the E2E stacks actually build.

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

### 3.3 The compose change — ONE service, **only** in the E2E stacks

Per memory + the deploy-flow design, **E2E runs on the disposable/dev stacks**
(which build `Dockerfile.dev`), not public stable. The sidecar goes in
`docker-compose.disp.yml` (the disposable E2E stack, :10044) and
`docker-compose.dev.yml`.

> **Do NOT add it unguarded to `docker-compose.yml`** — that is the **shared**
> parameterized channel file (`name: ezagent-${CHANNEL}`) used by nightly **and
> beta and stable**; only `cloudflared` is profile-gated there. An unguarded
> `chromium` service/env in that file would ship to **stable/prod**. If a beta
> smoke wants the sidecar, gate it behind a compose **`profiles: [e2e]`** (or a
> separate override file) so stable never starts it. The disp/dev files are
> already non-production, so adding it there directly is safe.

```yaml
# add to docker-compose.disp.yml (and docker-compose.dev.yml); NOT the shared
# docker-compose.yml without a profile guard:
  chromium:
    image: ghcr.io/browserless/chromium:<pinned-tag>   # verify tag at impl
    restart: unless-stopped
    environment:
      TOKEN: ${BROWSERLESS_TOKEN:?set BROWSERLESS_TOKEN}   # gitignored secret
      HOST: "0.0.0.0"            # bind so the ezagent sibling can reach it on the net
      PORT: "3000"
      CONCURRENT: "2"
      TIMEOUT: "120000"
      HEALTH: "true"
    # DELIBERATELY no `ports:` → not published to host/LAN (mirrors mihomo).
    # For TRUE egress isolation (no internet NAT), put chromium on an
    # `internal: true` docker network it shares with ezagent — absence of a proxy
    # env does NOT stop default outbound NAT. See the `networks:` block below.
    networks: [e2e_browser]
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:3000/?token=$${TOKEN} >/dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 15s

# on the ezagent service of the SAME stack, add:
    environment:
      E2E_BROWSER_CDP: "ws://chromium:3000?token=${BROWSERLESS_TOKEN}"   # see §3.2
      # ezagent must NOT route the CDP ws:// through mihomo — add to NO_PROXY:
      NO_PROXY:  "chromium,ezagent,localhost,127.0.0.1,::1,host.docker.internal,.feishu.cn,.larksuite.com,open.feishu.cn"
      no_proxy:  "chromium,ezagent,localhost,127.0.0.1,::1,host.docker.internal,.feishu.cn,.larksuite.com,open.feishu.cn"
      # allow the in-container navigation origin through Phoenix check_origin (§3.4)
      EZAGENT_EXTRA_CHECK_ORIGINS: "http://ezagent:10042"
    networks: [e2e_browser, ...existing...]
    depends_on:
      chromium:
        condition: service_healthy

# stack-level:
networks:
  e2e_browser:
    internal: true     # chromium+ezagent talk; NO internet egress from the browser
```

> Topology delta: **one service + a few env lines + one internal network**, in the
> **non-production** stacks only. Topology (a) is otherwise untouched. (This is a
> touch more than "two env lines" — the egress-isolation network and the
> `NO_PROXY`/`check_origin` entries are required for correctness, per the codex
> review folded in at §8.)

### 3.4 The check_origin gotcha (silent-failure trap — DO #3 correctness)

In-container, the browser (the sidecar) navigates to the app by an **internal**
origin. The credible internal URL is **`http://ezagent:10042`** (the compose
service name + container port) — **not** `world.localhost:10044`, which is a
host-side name not evidenced as resolvable inside the compose network, and not the
host port `:10044`, which the sidecar can't reach without a published port.

Phoenix's `check_origin` must allow that origin or the LiveView/React WebSocket
handshake is **rejected** → E2E fails with a blank page (a confusing silent
failure). **State of the world, corrected:** `docker-compose.prod.yml:111` sets
`EZAGENT_EXTRA_CHECK_ORIGINS` (Tailscale/localhost only), but
**`docker-compose.disp.yml` has NO `EZAGENT_EXTRA_CHECK_ORIGINS` at all** — it sets
`EZAGENT_PUBLIC_HOST: 100.64.0.27` + `EZAGENT_PUBLIC_PORT: 10044` (lines 28-30).
**Action:** on the ezagent service of the E2E stack, set
`EZAGENT_EXTRA_CHECK_ORIGINS: "http://ezagent:10042"` (shown in §3.3), **and** set
the in-container runbook's `BASE_URL=http://ezagent:10042` (see §3.5) so the origin
the browser uses matches the allowlist.

### 3.5 Runbook env — `BASE_URL` + `EVID_DIR` (two more env lines)

`docs/e2e/auto/lib.sh` already reads both from the environment with host defaults:
`BASE_URL="${BASE_URL:-http://world.localhost:10042}"` and
`EVID_DIR="${EVID_DIR:-<lib.sh dir>/../evidence}"`. **No runbook code change** — set
two env vars on the in-container ezagent service:

- `BASE_URL=http://ezagent:10042` — the internal app origin (matches §3.4's
  `check_origin` entry).
- `EVID_DIR=/data/e2e-evidence` — write screenshots onto the **persistent `/data`
  volume**, not the container-local `/app/docs/e2e/auto/evidence` (which is lost on
  recreate). The operator reads evidence from the `/data` volume as today.

So the deploy-mode delta to the runbook is **env only**: `E2E_BROWSER_CDP`,
`BASE_URL`, `EVID_DIR` (+ the one `connect` bootstrap in §3.2). Dev-mode (host)
leaves all three unset → today's behavior.

---

## 4. Security (DO #4)

| Concern | This spec |
|---|---|
| **Public ingress** | The `chromium` service has **no `ports:` mapping** → reachable only on the compose network (`chromium:3000`), never from host/LAN/internet. Same internal-only rule as the `mihomo` proxy. |
| **CDP auth** | `TOKEN` env gates the CDP endpoint (raw Chrome's debug port would be unauthenticated). Token is a gitignored secret (`BROWSERLESS_TOKEN` in `docker/.env.<channel>` / `secrets-*`), never committed — consistent with the existing secret pattern. |
| **Navigation scope** | Optionally pin the sidecar / runbook to the internal app origin via agent-browser `--allowed-domains` so the E2E browser can only reach the app under test. |
| **Egress** | The sidecar **needs no internet egress** (the app bundles its own assets: LV-SSR shell + React/shadcn rendered from `priv/`). **Correctness note (codex):** removing the mihomo proxy env does NOT stop default docker outbound NAT — true isolation requires an **`internal: true`** docker network shared with ezagent (§3.3). With that, the browser cannot reach the internet at all. |
| **Artifact egress (how screenshots get back)** | `screenshot`/`pdf`/`snapshot` return as **base64 over the CDP WebSocket**; agent-browser (running in the **ezagent** container) writes them to **its own** filesystem. **No shared volume** between the sidecar and ezagent; the only data crossing the boundary is the CDP stream. **Durability caveat (codex):** today `lib.sh` resolves `EVID_DIR` to `docs/e2e/auto/evidence` under `/app` — which is **container-local, not on a persisted volume** (`disp`/`dev` mount only `/data`, creds, layers). To keep evidence after the container is recreated, set `EVID_DIR` under `/data/...` (the persistent volume) or add an explicit evidence mount. See §3.5. |
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

1. **agent-browser binary install in `Dockerfile.dev`** (the E2E image) — what is
   the canonical pinned-install method (prebuilt release download vs `pnpm add -g`
   equivalent)? Must NOT trigger `agent-browser install` (that pulls Chrome, which
   we deliberately exclude). (Blocking for §3.1.)
2. **(NEW — codex) Does `connect` persist the session across subsequent CLI
   invocations?** The runbook does `connect` once, then many separate
   `agent-browser open/click/screenshot` processes (§3.2). This assumes the daemon
   keeps the attached CDP session alive between commands (as it does for a launched
   browser). **Verify** before relying on it — if `connect` is one-shot, the
   runbook needs a real wrapper change (e.g. `--cdp` on every command, or a
   long-lived session). This is the single biggest unproven assumption.
3. **Provider-mode vs generic-connect** against the **self-hosted** browserless
   image — verify whether `AGENT_BROWSER_PROVIDER=browserless` +
   `BROWSERLESS_API_URL` works zero-edit, or whether the self-hosted Sessions-API
   handshake differs (then use generic `connect`, the recommended default). §2.2.
4. **Pinned `ghcr.io/browserless/chromium` tag** for the v2 line (reproducible
   across the build-once-promote ladder); confirm the exact self-hosted
   `ws://...?token=` endpoint form for that tag. §2.2.
5. **Which stacks** carry the sidecar — disposable + dev only, or also beta for
   smoke (behind `profiles: [e2e]`)? Stable/prod: never. The shared
   `docker-compose.yml` must NOT get it unguarded. §3.3.
6. **Egress isolation network** — confirm an `internal: true` network shared by
   chromium+ezagent is acceptable (chromium loses all internet; ezagent keeps its
   existing networks for LLM/proxy). §3.3 / §4.

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

---

## 8. Codex adversarial review — verdict + what was folded in

**Verdict: REVISE → revised.** Codex confirmed the approach is "directionally right"
(internal-only chromium sidecar + generic CDP connect is the right shape) but caught
that the first draft over-claimed "verified" and under-scoped the delta. The
following findings were **verified against `origin/main` and folded into this spec**:

1. **Image gap was on the wrong Dockerfile.** disp/dev stacks build
   **`Dockerfile.dev`** (not `Dockerfile.prod`), and it too lacks agent-browser.
   → §3.1 corrected to target `Dockerfile.dev`. (verified: `docker-compose.disp.yml:12`)
2. **`connect`-session-persistence is an unproven assumption** (connect once → later
   `open` reuses it). → promoted to the **top open question** §6.2.
3. **Raw-Chrome Host-header vs `--remote-allow-origins` conflation** tightened — two
   distinct controls (HTTP `/json/*` Host allowlist vs WebSocket Origin). → §2.1/§2.2.
4. **"No proxy env" ≠ egress isolation** (docker still NATs outbound). → added an
   **`internal: true` network** for true browser egress isolation. §3.3/§4.
5. **Evidence dir is container-local** (`/app/docs/e2e/auto/evidence`), not on a
   persisted volume → screenshots lost on recreate. → §3.5 sets
   `EVID_DIR=/data/...`; §4 caveat. (verified: `lib.sh:11`, disp volumes)
6. **check_origin citation was wrong** — disp has NO `EZAGENT_EXTRA_CHECK_ORIGINS`
   (it sets `PUBLIC_HOST=100.64.0.27`/`PUBLIC_PORT=10044`); internal URL is
   `http://ezagent:10042`. → §3.4 corrected. (verified: `docker-compose.disp.yml:28-30`)
7. **`NO_PROXY` lacks `chromium`/`ezagent`** → CDP `ws://` could route through
   mihomo and fail. → added to the ezagent service env. §3.3.
8. **Shared `docker-compose.yml` would leak the sidecar to stable** (it's the
   nightly/beta/stable channel file). → §3.3 forbids unguarded add; use
   `profiles: [e2e]`. (verified: `docker-compose.yml:1-5,79-83`)
9. **Provider-mode not default** until verified vs self-hosted; generic connect is
   the default. → already §2.2/§3.2; reaffirmed.

Net effect: the headline shape (one internal-only chromium sidecar + endpoint
config, dev/disp only, never public prod) **stands**; the delta is honestly "one
service + a few env lines + one internal network," and the residual risk is
concentrated in the §6 open questions (chiefly OQ-2 connect-persistence and OQ-3
self-hosted browserless handshake), both verifiable in minutes at implementation.
