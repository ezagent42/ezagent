# Docker deployment — impact on agents' access to system functions, and the container-isolation question

**Status:** Investigation (research + recommendation, NOT implementation). 2026-06-27.
**Branch:** `docs/docker-agents-impact` (off `origin/main`; do NOT merge).
**Author:** Claude (agent dev), for the lead.
**Scope:** What breaks/changes for cc/codex/py/curl agents when ezagent deploys
in Docker instead of bare macOS; whether agents need separate/isolated
containers; how that connects to the deferred OS-sandbox task ("#112").

**Reads this builds on (current deploy direction — read these first):**
- `docs/notes/2026-06-24-cf-container-deploy-cost-analysis.md` (#941) — the
  resource-shape + "agents are erlexec subprocesses in the BEAM container" model.
- `docs/superpowers/specs/2026-06-25-deploy-flow-design.md` (#942/#996) — the
  **decided** topology: one `ezagent` container (BEAM + agents) + `postgres` +
  `mihomo` (egress proxy) + `cloudflared`, three channels (nightly/beta/stable)
  on one Mac via OrbStack, "build once, promote the artifact".
- `docs/together/2026-06-25/specs/py-agent-flavor-spec.md` §5 — the **trust
  model** ("posture A"), which is the discriminator for the whole question.
- `docker/Dockerfile.prod` — what is already baked into the image.

> **#112 numbering caveat (one line, then move on):** the lead's task names "#112"
> as the OS-sandbox-for-subprocess-flavors task. That is a **GitHub issue number**,
> not Decision Log #112 (which is the unrelated `Invocation.dispatch`→`Router.dispatch`
> consistency item — `docs/superpowers/specs/2026-05-30-post-lifecycle-system-remediation.md`).
> The in-repo content of the OS-sandbox task is **py-agent spec §5 "posture A"**.
> This note treats that as the authoritative #112 content.

---

## 0. TL;DR

1. **Docker barely changes the agent runtime — because the macOS model was
   already "everything on one host."** ezagent agents are not separate services;
   they are **OS subprocesses spawned in-process by the BEAM via erlexec**
   (`:exec.run/2`). Move the BEAM into a Linux container and the subprocesses
   spawn inside that same container exactly as they did on the Mac. `Dockerfile.prod`
   already bakes in the host binaries the agents shell out to (`claude`, `codex`,
   `uv`, `node`, `git`) — the one thing that genuinely had to change.

2. **The real breakages are NOT "Docker breaks agents" — they are two pre-existing
   host assumptions that Docker makes visible:** (a) the per-agent `config_dir`
   filesystem must be on a **persistent volume**, not ephemeral container disk;
   (b) **network egress** must go through a configured proxy (`mihomo` / `HTTPS_PROXY`)
   so `claude`/`codex`/`curl` can reach LLM/hex/npm. The deploy-flow stack already
   solves both. There is **no Chrome / agent-browser** in any production agent path
   (it is a dev/DoD verification tool), so its absence breaks nothing.

3. **Agents do NOT need separate containers today.** The correct topology is
   **(a) everything in one `ezagent` container** — which is exactly what the
   deploy-flow design already builds. Per-agent / per-flavor / sidecar containers
   would re-architect the erlexec spawn chokepoint into a remote-exec protocol
   (breaking `:exec.winsz`, `:stdin`, the orphan reaper, pid-files, and `{:spawned_by}`
   lineage that all assume a local PID) for **zero security benefit under the
   current trust model**.

4. **The #112 connection is a substitution, not a complement.** Container-per-agent
   (topology c/d) **is one possible implementation of the OS sandbox** — an
   alternative to the seccomp/namespaces/low-priv-user approach py-agent §5 names.
   Both are gated by the **same single trigger** that §5 already states: ezagent
   admitting **untrusted (non-operator) agent authors**. Until that trigger fires,
   neither the OS sandbox nor per-agent containers are needed.

**The one strategic question for the lead** (it decides whether *any* isolation
work is ever needed): **will ezagent ever admit non-operator / untrusted agent
authors?** If no → topology (a) is permanent. If yes → that, not Docker, is what
forces per-agent isolation, and (c)/(d) + the OS sandbox become the same project.

---

## 1. Per-flavor system-resource map (what each agent actually uses)

Every "agent" is a `Ezagent.Entity.Agent` Kind (a BEAM GenServer) of a given
**flavor**. The flavor decides whether it reaches outside the BEAM at all, and how.

| Flavor | Host binary? | OS subprocess? | Spawn chokepoint | Writable FS (`config_dir`) | Network egress | Real browser? |
|---|---|---|---|---|---|---|
| **cc** | `claude` (+`node`,`git`) | **yes** — PTY child | `Ezagent.Domain.Pty.Server` `:exec.run/2` | **yes** — `<ns>-agents/<ws>/<name>` chmod 700; creds + `.mcp.json` + settings written before launch | yes — claude→Anthropic API; MCP bridge to BEAM | **no** |
| **codex** | `codex` (+`node`) | **yes** — PTY child | same `Domain.Pty.Server` (`cmd_override` argv) | **yes** — per-agent `CODEX_HOME` (auth.json) | yes — codex→OpenAI API | **no** |
| **py** | `uv` / python | **yes** — JSON-RPC child | `Ezagent.Domain.Python.Server` `:exec.run/2` | **yes** — config_dir holds the role script (`agent.py`); np whitelist is in-script | only if the script makes calls (np = pure numpy/sympy, none) | **no** |
| **curl** | **none** | **NO** | n/a — `:httpc` **inside the BEAM** | no | yes — in-BEAM HTTP to OpenAI-shape APIs (DeepSeek/OpenAI) | **no** |

Supporting runtime processes (not agents, but part of the picture):

| Process | Binary | Subprocess? | Notes |
|---|---|---|---|
| **Feishu WS sidecar** | `node` | **yes** — one long-lived node process | `ezagent_plugin_feishu` ws_sidecar; node_modules bundled into release `priv/` at build time; runtime only needs `node` to run `main.js`. |
| **Egress proxy** | `mihomo` | separate **container** (compose service) | All agent/cloudflared egress routed via `${ESR_PROXY}` / `HTTPS_PROXY`; `NO_PROXY` covers feishu/localhost. |
| **Orchestrator worker-spawn** | — | spawns **BEAM Kinds**, not OS procs | `Ezagent.SpawnRegistry.spawn/1` is URI-scheme→spawn-fn for **Kinds** (GenServers). It does **not** spawn OS processes — that is the two erlexec servers above. Do not conflate them. |

### Key code citations

- **cc/codex PTY chokepoint:** `apps/ezagent_domain_pty/lib/ezagent/domain/pty.ex`
  (facade) → `.../ezagent_domain_pty/server.ex` — `:exec.run/2` (erlexec) PTY
  allocation; `cmd_override` (argv list, no shell → no flag injection), `cmd_env`
  (e.g. `CLAUDE_CONFIG_DIR`), `cwd`, `:exec.winsz(os_pid, 40, 120)` (claude TUI
  blocks on TIOCGWINSZ), `:stdin`, `:monitor` for `{:DOWN,...}`.
- **py chokepoint:** `apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex`
  — "Sibling of `Domain.Pty.Server` — both wrap `:exec.run/2`"; argv built from
  `uv`; `{:cd, cwd}`; `:uv_not_found` phase if `uv` absent.
- **curl is in-BEAM:** `apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/api_client.ex`
  — uses `:httpc` (Erlang stdlib). **No subprocess, no host binary.** This flavor
  is unaffected by any container/spawn topology decision.
- **per-agent config_dir authority:** `apps/ezagent_core/lib/ezagent/sandbox/config_dir.ex`
  — `<Home.path("<ns>-agents")>/<ws>/<name>/` chmod 700, allocated by the domain,
  materialized by the flavor plugin. `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex`
  — "every spawned agent gets its OWN config dir."
- **what's baked into the image:** `docker/Dockerfile.prod` runtime stage —
  `npm i -g @anthropic-ai/claude-code@2.1.162 @openai/codex@0.137.0`, `uv` install,
  `nodejs` 22, `git`; `node_modules` for the feishu sidecar bundled at build time;
  runs as non-root `ezagent` user (erlexec refuses root, needs `SHELL`).
- **spawn lineage:** `apps/ezagent_core/lib/ezagent/agent_lineage.ex` — `agent_uri →
  spawned_by_uri` (ETS + durable Identity slice), backs `{:spawned_by, P}` CapBAC.
  This is **BEAM-internal bookkeeping**, not OS process ancestry.
- **orphan reaper (local-PID assumption):** `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/orphan_reaper.ex`
  — reaps stale `claude` OS processes left by a SIGKILLed BEAM, discovered via
  **pid files the PtyServer writes locally**. Assumes the child PID is reachable
  from the BEAM's own host/namespace.

### Resource requirements distilled

- **Need a host binary in the image:** cc, codex, py, feishu-sidecar. (curl: none.)
- **Need a writable, persistent `config_dir`:** cc, codex, py.
- **Need network egress (via proxy):** cc, codex, curl; py only if its script does.
- **Need OS process-spawn (erlexec):** cc, codex, py. (curl: no.)
- **Need a real browser:** **none.** (See §2.4.)

---

## 2. What changes under Docker

The macOS deployment implicitly assumed: binaries on `$PATH`, a writable `$HOME`,
direct network, and a host the orchestrator and its subprocesses **share**. Docker
keeps the *share* (subprocesses spawn in the same container) but makes the other
three explicit.

### 2.1 Binaries must be in the image — DONE

`Dockerfile.prod` already installs `claude`/`codex`/`uv`/`node`/`git` into the
runtime stage and bundles the feishu sidecar's `node_modules`. ABI-compatibility
for the erlexec C port is handled by using the same Debian base for builder and
runtime + `include_erts`. **No gap here.** A missing binary surfaces cleanly
(py → `:uv_not_found` phase; cc's `McpConfigWriter` would raise `:enoent` if `git`
absent — which is why `git` is explicitly installed).

### 2.2 Per-agent `config_dir` filesystem — volume, not ephemeral

Each agent's `config_dir` holds **non-reconstructible state**: OAuth/API creds,
`.mcp.json`, settings, and (for py) the role script. On bare macOS this lived in
`~/.ezagent` and was durable by default. In Docker, container disk is **ephemeral**
(lost on restart/recreate). The deploy stack handles this: `entrypoint.prod.sh`
sets `EZAGENT_HOME=/data`, a **bind-mounted/named-volume stable home**, and
recreates the home skeleton on a clean volume. So `config_dir`s persist across
container restarts.

- **On the Mac (current target):** native SSD volume — no cap, full speed. Clean.
- **On CF Containers (the alternative, #941):** ephemeral 20 GB cap → would need
  R2-FUSE for the durable slice (slower) or snapshots. This is a **CF-specific**
  concern, not a Docker-on-Mac concern, and #941 already costed it. The
  deploy-flow design chose Mac, so this does not bite today.

### 2.3 Network egress — proxy, not direct

`claude`/`codex` (and `curl`'s `:httpc`, and `cloudflared`) need outbound to
LLM/hex/npm. The stack routes egress through the `mihomo` container via
`HTTPS_PROXY`/`${ESR_PROXY}`, with `NO_PROXY` for feishu/localhost. This mirrors
the memory note "agents need proxy env on the node so they inherit it; missing →
403." The build stage separately threads a build-time proxy and **clears it from
the final image** (runtime proxy comes from compose). No gap.

### 2.4 The host-vs-container boundary the macOS model assumed

The macOS model assumed the agent could touch *the operator's whole machine*
(`agent-browser` → the real Chrome the human uses, arbitrary host tools).
**Under Docker that ambient host access goes away — and that is a feature, not a
breakage**, because:

- **agent-browser → Chrome is NOT a production agent capability.** Grep of
  `apps/**/lib/**` finds no `playwright`/`puppeteer`/`chromium`/browser-driving in
  any flavor's runtime path. agent-browser is the **dev/DoD verification tool**
  (the human dev screenshots the UI; memory `feedback_agent_browser_debug`), and
  the hello/world plugins *generate* HTML — they do not drive a browser. So Chrome's
  absence from the image breaks **no agent runtime**.
- The narrowing of ambient host access is exactly the direction the trust model
  (§4) wants. The container boundary is already a coarse sandbox around the *whole*
  agent fleet.

> **Open item (not a breakage):** if a *future* role is meant to drive a real
> browser (e.g. a web-automation agent), that role would need Chromium +
> playwright/puppeteer baked into the image (or a dedicated browser sidecar). No
> such role exists today. Flag for the lead only if it's on the roadmap.

### 2.5 Process limits / reaping

erlexec reaps children on graceful BEAM exit via SIGTERM. A **brutal** BEAM kill
(SIGKILL/SEGV) orphans the `claude` child; the orphan reaper cleans it up via
pid-files on next boot. Inside a container this is **simpler, not harder**: the
container's PID namespace bounds the blast radius, and a container restart starts
from a clean process table. No new problem; arguably an improvement.

---

## 3. The isolation question — should agents run in separate containers?

The lead asked us to evaluate four topologies. The discriminator is **§4 (trust
model)**, not Docker mechanics.

### Topology comparison

| | Topology | Isolation/security | Resource control | Spawn latency | Spawn-model impact | PTY / config_dir plumbing |
|---|---|---|---|---|---|---|
| **(a)** | **Everything in one `ezagent` container** (current deploy-flow design) | Coarse: one boundary around the whole fleet. Adequate **iff all authors are operators** (§4). | Per-workspace container limits (the deploy unit). No per-agent quota. | **None** — `:exec.run/2` in-process. | **Unchanged.** erlexec spawns local PIDs. | **Local, works as-is.** PtyServer ↔ child share namespace; config_dir on the mounted volume. |
| **(b)** | **Sidecar "agent-runtime" container** (BEAM in one, all subprocesses in another) | Marginal: separates BEAM from agents, but all agents still share the sidecar → no per-agent isolation. | One extra boundary; still no per-agent quota. | Low-moderate: needs a cross-container exec channel. | **Breaks the chokepoint.** `:exec.run` must become a remote-exec RPC to the sidecar. | **Breaks.** PTY master/slave, `winsz`, `stdin`, pid-files, reaper, and config_dir all cross a container boundary → re-plumb over a protocol + shared volume. |
| **(c)** | **Per-agent ephemeral container** (one container per Agent Kind) | **Strong** per-agent isolation — this *is* an OS sandbox. | Per-agent cgroup quotas; clean teardown. | **High** — container create per agent spawn; cold-start on every (re)hydrate. | **Rewrites the spawn model** into "spawn a container," plus lifecycle/restart/snapshot semantics (the Lifecycle `activate/2` re-spawn becomes container orchestration). | **Heavy re-plumb.** Everything in (b) plus per-agent volume mounts + a PTY-over-network bridge for every agent. |
| **(d)** | **Per-flavor container** (one cc-runtime, one codex-runtime, one py-runtime) | Medium: flavor-level blast-radius separation; **no isolation between two agents of the same flavor** (the common case). | Per-flavor quota; coarser than (c). | Moderate: containers long-lived but exec still crosses a boundary. | Same chokepoint rewrite as (b)/(c), scoped per flavor. | Same cross-boundary PTY/config_dir re-plumb as (b). |

### What "spawn a container" actually costs (the strongest "what breaks")

Topologies (b)/(c)/(d) all share one structural cost: the **two erlexec
chokepoints** (`Domain.Pty.Server`, `Domain.Python.Server`) assume the child is a
**local PID in the BEAM's own namespace**. Concretely, these all break across a
container boundary and would each need a networked replacement:

- `:exec.winsz(os_pid, rows, cols)` — TTY ioctl on a local PID (claude TUI blocks
  without it).
- `:stdin` / PTY master read-write — the live terminal stream the LiveView xterm
  attaches to (`ezagent_domain_ui/pty/terminal.ex`).
- pid-files + **orphan reaper** — discovery + SIGKILL of a local OS process.
- `:monitor` → `{:DOWN, ...}` — local port monitoring for phase transitions.
- per-agent `config_dir` — currently a local path the child opens directly; would
  become a mounted volume per container.

`{:spawned_by}` **lineage is BEAM-internal** (ETS + durable slice in
`agent_lineage.ex`) and is unaffected by where the OS child runs — so CapBAC does
*not* force any topology. But the PTY/terminal/reaper plumbing is a real
re-architecture, not a config flag. **This is the price of (b)/(c)/(d), and it
buys security only if §4's trigger has fired.**

### Recommendation: **(a) — everything in one container — for now**

Reasons, in priority order:

1. **It matches the current trust model (§4).** Operators already run cc with
   node-level access; per-agent isolation defends against a threat that does not
   exist yet (untrusted authors). Building isolation now is defending an empty
   room.
2. **It matches the decided deploy direction.** `2026-06-25-deploy-flow-design.md`
   already builds exactly (a): one `ezagent` container per environment, "build once
   promote artifact." Diverging would re-open a settled, working design.
3. **It preserves the spawn chokepoint as-is.** No PTY-over-network bridge, no
   remote-exec protocol, no per-agent container lifecycle. The Lifecycle
   `activate/2` re-spawn stays an in-process `:exec.run`.
4. **The container is already a sandbox — around the fleet.** Non-root `ezagent`
   user, no host Chrome, proxy-gated egress, PID-namespace-bounded reaping. That
   is meaningful hardening over bare-macOS ambient access, at zero extra cost.
5. **The deployment unit is the workspace, not the agent.** `#941` /
   `workspace-as-deployment-unit.md`: the BEAM node holds a workspace's live
   session/PTY state on one node and **cannot be sharded** — which already argues
   against splitting one workspace's agents across containers.

**When (a) stops being right** (the upgrade path, in order of likelihood):

- **§4 trigger fires (untrusted authors):** go to **(c) per-agent** — it *is* the
  OS sandbox (see §4). Pair with the spawn-chokepoint rewrite. This is the only
  trigger that justifies the cost.
- **Resource abuse by a runaway agent within a trusted fleet:** consider
  in-container limits first (cgroups on the erlexec child, `ulimit`, nice) before
  reaching for (c). Cheaper, no re-plumb.
- **A genuinely heavyweight/hostile flavor** (e.g. a future browser-automation or
  build-farm flavor) → **(d) per-flavor** for that flavor only, keeping (a) for the
  rest. Hybrid is fine.

(b) sidecar is **not recommended at any stage** — it pays the cross-boundary
re-plumb cost of (c)/(d) without their per-agent or per-flavor isolation benefit.

---

## 4. Connection to #112 (the OS-sandbox-for-subprocess-flavors task)

**The authoritative content of "#112" is py-agent spec §5 "posture A":**

> "OS sandboxing (seccomp/namespaces/low-priv user) is required ONLY to admit
> untrusted (non-operator) authors — not a current need; the single condition that
> reopens this." … "an operator-authored python script is not a new privilege for
> an actor with node-level trust."

This gives a clean, two-part answer to the lead's question 4:

1. **Container-per-agent (topology c/d) IS an implementation of the OS sandbox —
   not a complement to it.** §5 lists "seccomp / namespaces / low-priv user" as
   the sandbox primitives. A per-agent **container** delivers exactly those
   (namespaces + cgroups + a non-privileged user) as a packaged unit. So choosing
   (c) and "doing #112" are **the same project**, two implementations of one goal:
   - **seccomp/namespaces in-process** = keep topology (a), add sandbox profiles to
     the erlexec child (finer-grained, lower latency, harder to get right per flavor).
   - **container-per-agent** = topology (c), the sandbox boundary IS the container
     (coarser, higher spawn cost, operationally simpler, reuses the deploy substrate).
   They are alternatives; you would pick one, not stack both.

2. **Both are gated by the same single trigger §5 already names: untrusted
   authors.** Today every agent author is an operator with node-level trust (the
   create-cap = authorship gate, `RoleStep.mint_and_grant_caps` under caller
   authority, CapMint fail-closed). So **neither the OS sandbox nor per-agent
   containers are needed now.** Docker does **not** change this calculus —
   containerizing the deployment does not introduce untrusted authors; it just
   moves the same trusted fleet into a Linux box.

**Therefore #112 and the container-topology question collapse into one decision,
governed by one input:** *does ezagent admit non-operator agent authors?* If/when
yes, the cheapest path is likely **(c) per-agent containers reusing the Docker
substrate** as the #112 OS sandbox — because the deploy stack already produces and
runs containers, so "the sandbox is a container" is less net-new than authoring
per-flavor seccomp profiles. That tradeoff should be re-evaluated at decision time
against latency needs.

---

## 5. Open questions for the lead

1. **(Strategic — gates everything)** Will ezagent ever admit **non-operator /
   untrusted agent authors**? This single answer decides whether *any* isolation
   work (OS sandbox or per-agent containers) is ever needed. If "no, operator-only
   forever," topology (a) is permanent and #112 stays closed.
2. **If untrusted authors are coming:** prefer **per-agent containers (c) reusing
   the Docker substrate** as the #112 sandbox, or **in-process seccomp/namespace
   profiles** on the erlexec child (topology a + sandbox)? The former is less
   net-new given the deploy stack; the latter is lower-latency but per-flavor work.
3. **Browser-driving roles on the roadmap?** No production agent drives a real
   browser today (agent-browser is dev-only). If a web-automation flavor is planned,
   it needs Chromium + playwright in the image **or** a dedicated browser sidecar —
   flag now so the image/topology accounts for it.
4. **Per-agent resource limits within trusted (a)?** Even without untrusted authors,
   a runaway agent can saturate the workspace container (no per-agent quota in (a)).
   Worth cheap in-container limits (cgroups/ulimit on the erlexec child) before any
   topology change?
5. **CF Containers vs Mac confirmation.** The deploy-flow design chose Mac+tunnel;
   #941's 20 GB ephemeral-disk + 4-vCPU ceilings only bite on CF. Confirm Mac is the
   settled substrate so the config_dir-durability story stays "native volume" (clean)
   rather than "R2-FUSE" (slow).

---

## 6. Sources (in-repo, read via `git show origin/main:<path>`)

- `docker/Dockerfile.prod`, `docker/entrypoint.prod.sh`
- `apps/ezagent_domain_pty/lib/ezagent/domain/pty.ex` + `.../server.ex`
- `apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex`
- `apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/api_client.ex`
- `apps/ezagent_core/lib/ezagent/sandbox/config_dir.ex`,
  `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex`
- `apps/ezagent_core/lib/ezagent/spawn_registry.ex`,
  `apps/ezagent_core/lib/ezagent/agent_lineage.ex`
- `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/orphan_reaper.ex`
- `apps/ezagent_plugin_py/priv/python/np.py`
- `docs/notes/2026-06-24-cf-container-deploy-cost-analysis.md`
- `docs/superpowers/specs/2026-06-25-deploy-flow-design.md`
- `docs/together/2026-06-25/specs/py-agent-flavor-spec.md` (§5 posture A = #112 content)
- `docs/together/2026-06-26/handoffs/allenwoods-deploy-finalize.md`
