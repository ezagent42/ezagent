# Multi-Repo Split — umbrella → N repositories — PLAN

- **Date**: 2026-07-24
- **Status**: DRAFT for review — design/migration plan only, no implementation
- **Read off**: `origin/main` @ `e7a153a92` (all `mix.exs` dep edges, CI/gate/release facts, and extraction-chunk status re-verified at this SHA)
- **Decision owner**: Allen (motivation, 2026-07-24: the umbrella is now very large; every change loads a huge context and risks *modification leakage* — edits bleeding across unrelated concerns. Splitting into repos bounds each change's blast radius and context.)
- **Companion spec**: `docs/superpowers/specs/2026-07-23-actor-framework-umbrella-extraction.md` (FINAL v3) — the in-flight actor-framework extraction this plan sequences against. Chunks **C0–C3 have landed** on `origin/main` (`21cc15575` #1546, `a6f256394` #1548, `32a3335f3` #1550, `fe35163f3` #1561); C4–C7 outstanding.

---

## 0. Summary of the recommendation

- **Target topology: 6 code repos + the existing deploy repo** (§2): `ezagent-actor` (framework substrate), `ezagent-platform` (core spine + the collaboration domains + cli), `ezagent-agents` / `ezagent-connectors` / `ezagent-social` (three plugin clusters), `ezagent-product` (web + release + integration suite), `ezagent-deploy` (already separate — `Hyprial/ezagent-deploy`, see its README: "This repo owns everything about *running* ezagent; the app repo owns only the code").
- **Cross-repo mechanism: tag-pinned git deps** through a single `ezagent_dep/1` mix.exs helper with three modes (in-repo umbrella / workspace path-override for dev / git+tag canonical), with a self-hosted Hex mini-registry as a later, explicitly-triggered upgrade (§3).
- **Sequencing: the actor extraction's consumer-migration chunks gate the split.** No app leaves the umbrella while it still holds actor-boundary allowlist debt; `ezagent-actor` is the first repo out, after C5 (physical move) and ideally C7 (allowlist `[]`) (§4).
- **Gates travel with the contract owner**: each boundary scanner ships as a library module in the repo that owns the contract, consumer repos run it over their own `lib/` in their gate, and `ezagent-product` re-runs the union over `deps/**/lib` as the backstop — no violation can hide, because the product repo fetches full source of every git dep (§5).
- **Migration is phased and reversible**: Phase 0 decoupling happens entirely in-umbrella; each extraction is `git filter-repo` (history preserved) + a dep-mode flip; the umbrella stays buildable at every phase (§6).

---

## 1. Current structure — the real dependency DAG

### 1.1 The 28 umbrella apps (lib LOC, `origin/main`)

| Tier | App | lib LOC | prod `in_umbrella` deps (from `apps/<app>/mix.exs`) |
|---|---|---:|---|
| 0 | `ezagent_core` | 52,270 | — (umbrella bottom; zero `in_umbrella` deps) |
| 1 | `ezagent_domain_identity` | 13,389 | core |
| 1 | `ezagent_domain_agent_bridge` | 1,460 | core |
| 1 | `ezagent_domain_git` | 2,158 | core |
| 1 | `ezagent_domain_pty` | 2,679 | core |
| 1 | `ezagent_domain_python` | 1,791 | core |
| 2 | `ezagent_domain_agent` | 11,013 | core, identity, agent_bridge |
| 2 | `ezagent_domain_provider_connection` | 11,914 | core, identity |
| 2 | `ezagent_domain_external_mirror` | 7,389 | core, identity |
| 3 | `ezagent_domain_workspace` | 10,276 | core, agent, git, identity |
| 4 | `ezagent_domain_session` | 32,614 | core, identity, workspace, external_mirror, pty, agent_bridge, agent |
| 4 | `ezagent_domain_ui` | 4,431 | core, pty, identity, workspace, external_mirror |
| 5 | `ezagent_domain_socialware` | 3,037 | core, identity, session, external_mirror, ui |
| 6 | `ezagent_plugin_native` | 300 | core, agent, workspace |
| 6 | `ezagent_plugin_curl_agent` | 1,324 | core, identity, workspace, agent_bridge, agent, session |
| 6 | `ezagent_plugin_cc` | 8,538 | core, agent, identity, workspace, agent_bridge, ui, pty, session |
| 6 | `ezagent_plugin_codex` | 2,641 | core, agent, session, workspace, agent_bridge, pty, **plugin_cc** |
| 6 | `ezagent_plugin_py` | 1,432 | core, agent, agent_bridge, session, workspace, **python** |
| 6 | `ezagent_plugin_email` | 2,102 | core, identity, external_mirror, session |
| 6 | `ezagent_plugin_feishu` | 4,461 | core, identity, workspace, session, external_mirror (+ plugin_cc `only: :test`) |
| 6 | `ezagent_plugin_github` | 1,644 | core, **git**, **provider_connection** |
| 6 | `ezagent_plugin_protocol_api` | 904 | core, agent, session, external_mirror |
| 6 | `ezagent_plugin_kanban` | 3,550 | core, workspace, agent, identity, session, ui |
| 6 | `ezagent_plugin_hello` | 5,569 | core, session, socialware, ui, identity, workspace, **plugin_native**, agent_bridge, agent, **plugin_curl_agent** |
| 6 | `ezagent_plugin_world` | 12,278 | core, agent, agent_bridge, external_mirror, pty, identity, session, workspace, ui, **plugin_hello** |
| 6 | `ezagent_plugin_kb` | 757 | core, agent, identity (prod); workspace, session, agent_bridge, plugin_codex, plugin_world all `only: :test` |
| 7 | `ezagent_web` | 8,410 | 8 domains + **all 13 plugins** (prod) |
| 7 | `ezagent_cli` | 1,966 | core, agent, identity, workspace, session |

Total lib ≈ 210K LOC. All edges verified against each `apps/*/mix.exs` at
`e7a153a92`. Note one grep-trap corrected during this census:
`apps/ezagent_domain_external_mirror/mix.exs:55` contains the string
`{:ezagent_domain_session, in_umbrella: true}` **inside a comment** ("DO NOT
add … here as a runtime dep") — the real edge is `session → external_mirror`
only; the DAG is acyclic, as `im_session_agent_acyclic_test.exs` +
`undeclared_umbrella_dep_test.exs` enforce.

### 1.2 Structural facts that shape the split

1. **`ezagent_core` is the bottom and the biggest** (52K LOC): actor framework
   (being extracted → `ezagent_actor`, spec 2026-07-23 §1/§3), the cap/authority
   spine (#195-active, stays in core per spec §3.3), URI, message store,
   `EzagentCore.Repo` + **all** Ecto migrations
   (`apps/ezagent_core/priv/repo/migrations/` is the only migrations dir in the
   umbrella).
2. **Plugin→plugin prod edges exist and force clustering**: `codex → cc`,
   `hello → native + curl_agent`, `world → hello`. Cross-cluster *test-only*
   edges: `feishu → cc (:test)`, `kb → codex + world (:test)`.
3. **`ezagent_web` is the assembly point, with real compile deps on plugins**:
   the router references `EzagentPluginWorld.WorldLive` by module atom
   (`apps/ezagent_web/mix.exs:91-93`), the Feishu webhook route needs
   `EzagentPluginFeishu.WebhookPlug` "at compile time so the router macro
   resolves the module atom" (`mix.exs:96-99`), the CC WS Socket is mounted in
   `EzagentWeb.Endpoint` (`mix.exs:104-107`); plus
   `live_auth.ex`, `session_feed_channel.ex`, `hello_delegation_controller.ex`,
   `socialware/kanban_published_read_adapter.ex`.
4. **Core deliberately references upper modules only as bare atoms** (IoC
   backbone). `undeclared_umbrella_dep_test.exs` documents this: "core
   REFERENCES domain modules this way constantly (it cannot compile-dep on a
   domain — that would be a cycle)". Bare-atom wiring (flavor maps, registries,
   `authority_loader` config → `Ezagent.Identity.read_held_caps/1`) survives a
   repo split unchanged: it is runtime wiring resolved in the assembled release.
5. **Plugins are declaration-only** (`use Ezagent.Plugin`, `Ezagent.Plugin.boot/1`
   registers `behaviors/0`/`roles/0`/`children/0` — e.g.
   `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`:
   "纯 plugin（路 A）… 框架的 `Ezagent.Plugin.boot/1` 代为注册，作者不碰任何
   `*Registry`", enforced by the `:ezagent_plugin_check` compiler). This is the
   north-star property that makes plugin repos viable at all.
6. **The release is a single explicit-list umbrella release** (root
   `mix.exs` `releases/0`): "the plugins are NOT in ezagent_web's dep tree
   (they're started as sibling apps), so EVERY runnable app must be listed
   explicitly or it silently won't boot in the release"; `ezagent_cli` is
   task-only `:load`.
7. **Build-time cross-app reach-ins that a split must dissolve**: the web app's
   asset aliases run `cmd --cd ../ezagent_plugin_world/assets npm install/build`
   (`apps/ezagent_web/mix.exs:151-180`), and the kanban/hello/autoservice
   socialware seed packages live in `apps/ezagent_web/priv/socialware_seed/`
   (kanban application.ex NOTE).
8. **CI is layered and self-hosted** (`.github/workflows/ci.yml`): `frontend` →
   `gate` (deterministic, dockerized on the mac, ~3-5 min; runs `mix gate.arch`
   over `@arch_invariant_test_paths`, root `mix.exs`) → `full-suite` (native
   mac, sharded `mix ci.shard.<shard>` legs: static / e2e / core / session /
   web / plugin / domain, parity proven by `ci_shard_parity_test` +
   `mix ci.shard.verify`). Gates are umbrella-wide source scans with
   cross-app path anchors (e.g. `ezagent.arch.scan.ex` `@def_count_files`
   spans cc/session/core files; `@spawn_registry_sanctioned_files` spans 5 apps).

---

## 2. Proposed repo boundaries

The split follows the DAG's natural cut-points: the framework substrate
(no deps), the platform spine (dense, co-evolving domain cluster), three
plugin clusters (grouped by their real plugin→plugin edges), and the assembly.

```
                    ┌───────────────────────────────────────────────┐
                    │            ezagent-product  (R5)              │
                    │  ezagent_web · release def · integration/e2e  │
                    └──────┬───────────┬──────────────┬─────────────┘
                           │           │              │
              ┌────────────▼──┐  ┌─────▼────────┐  ┌──▼───────────────┐
              │ ezagent-social│  │ ezagent-     │  │ ezagent-agents   │
              │ (R4) world,   │  │ connectors   │  │ (R2) cc, codex,  │
              │ hello, kanban,│  │ (R3) feishu, │  │ py, native,      │
              │ kb            │  │ email, github│  │ curl_agent,      │
              └──────┬───┬────┘  │ protocol_api,│  │ domain_python    │
                     │   │       │ provider_conn│  └──┬───────────────┘
                     │   └───────┴──────┬───────┘     │
                     │  (R4→R2: hello→native/curl)    │
              ┌──────▼─────────────────▼──────────────▼──┐
              │           ezagent-platform  (R1)         │
              │  ezagent_core + identity, agent_bridge,  │
              │  agent, git, workspace, external_mirror, │
              │  pty, session, ui, socialware, cli       │
              └──────────────────┬───────────────────────┘
                                 │
              ┌──────────────────▼───────────────────────┐
              │            ezagent-actor  (R0)           │
              │  the extracted actor framework (C5 app)  │
              └──────────────────────────────────────────┘

              ezagent-deploy (R6, exists) → builds/runs R5's release
```

### R0 — `ezagent-actor` (~9–10K LOC)

- **Apps**: `ezagent_actor` (the C5 physical-move app, spec §3.2 inventory:
  `kind/server.ex`, `invocation.ex`, `router.ex`, snapshot/lifecycle/registry/
  ready-gate/pending-delivery/idempotency, `uri.ex` + `SchemeRegistry`, the
  Kind/Behavior authoring contract).
- **Why this boundary**: it is the one app designed to have **zero in-umbrella
  deps** ("`ezagent_actor/mix.exs` declares NO in_umbrella deps … `mix compile`
  inside `apps/ezagent_actor` against only its declared deps is the
  standalone-compile acceptance check", spec §3.1/§7.2). Its public surface
  (§2.2 read/dispatch/lifecycle + §2.3 authoring plane) is an explicit,
  gate-enforced contract; its upward needs are 9 ports + 2 config injections
  (§3.4). That is a repo boundary already designed to spec.
- **Depends on**: hex only (`ecto_sql`, `phoenix_pubsub`, `telemetry`).
- **Also the only candidate for eventual public/Hex publication.**

### R1 — `ezagent-platform` (~143K LOC)

- **Apps**: `ezagent_core`, `ezagent_domain_identity`, `ezagent_domain_agent_bridge`,
  `ezagent_domain_agent`, `ezagent_domain_git`, `ezagent_domain_workspace`,
  `ezagent_domain_external_mirror`, `ezagent_domain_pty`,
  `ezagent_domain_session`, `ezagent_domain_ui`, `ezagent_domain_socialware`,
  `ezagent_cli`. Owns `EzagentCore.Repo` + **all migrations** (the extraction
  spec's rule generalizes: "migrations are a deploy-repo/Repo concern" — the
  Repo owner keeps the single migrations dir; extracted repos contribute
  migrations via platform PRs).
- **Why one repo, not two+**: this cluster is *dense and co-evolving*. The cap
  spine spans `core/cap/*` **and** identity (`EntityCaps`, `behavior/identity.ex`
  — see `@cap_verify_fail_loud_targets` in `ezagent.arch.scan.ex`, which anchors
  one invariant across both apps); core's `authority_loader` config points into
  identity; session touches 6 sibling domains. Cutting through the #195-active
  spine repeats exactly the mistake the extraction spec rejected in §3.3
  ("moving `cap/*` mid-workstream collides with an active branch family for
  zero boundary gain"). `ezagent_cli` deps are all platform apps, and it ships
  in the release as `:load`.
- **Depends on**: R0.
- **Flagged as the Phase-4 candidate for a further split** (identity/cap spine
  vs collaboration domains) **after** #195 settles — not now.

### R2 — `ezagent-agents` (~16K LOC)

- **Apps**: `ezagent_plugin_cc`, `ezagent_plugin_codex`, `ezagent_plugin_py`,
  `ezagent_plugin_native`, `ezagent_plugin_curl_agent`, **plus
  `ezagent_domain_python`** (its sole consumer is `plugin_py`; the domain moves
  with its only customer).
- **Why this boundary**: the agent-backend plugins form a real dep cluster
  (`codex → cc` prod edge) and a single concern: agent flavors/transports.
  These iterate together (cc custom backends, codex bridge work).
- **Depends on**: R1 (and R0 transitively).

### R3 — `ezagent-connectors` (~21K LOC)

- **Apps**: `ezagent_plugin_feishu`, `ezagent_plugin_email`,
  `ezagent_plugin_github`, `ezagent_plugin_protocol_api`, **plus
  `ezagent_domain_provider_connection`** (11.9K; sole consumer is
  `plugin_github` — moves with its only customer).
- **Why**: external-channel/integration plugins; no prod edges to any other
  plugin cluster. `feishu → cc` is `only: :test` — resolved in §2.1(4).
- **Depends on**: R1.

### R4 — `ezagent-social` (~22K LOC)

- **Apps**: `ezagent_plugin_world`, `ezagent_plugin_hello`,
  `ezagent_plugin_kanban`, `ezagent_plugin_kb`.
- **Why**: the product/social-UX cluster with its own internal dep chain
  (`world → hello`); world's React/shadcn asset tree lives here.
- **Depends on**: R1 + R2 (prod edge `hello → native, curl_agent`). `kb`'s
  test-only deps on codex/world: world is in-repo; codex per §2.1(4).

### R5 — `ezagent-product` (~9K LOC + integration suites + seeds)

- **Apps**: `ezagent_web`; plus the **release definition** (the root
  `releases/0` explicit list moves here verbatim, same rationale comment), the
  cross-repo **integration/e2e suite** (today's `e2e` + `web` shards and the
  cross-cluster test-dep tests), and the **socialware seed aggregation**
  (`priv/socialware_seed/*` — seed packages either stay here as deploy data or
  move to their plugin repos with product aggregating at build; recommend
  move-with-plugin, aggregate-at-build).
- **Why**: web is the only app that compile-deps on everything (§1.2.3); the
  repo that assembles is the repo that pins. Product owns `config/runtime.exs`
  / prod config and the version pin set (the "release train").
- **Depends on**: R0–R4 (all).

### R6 — `ezagent-deploy` (exists)

Unchanged role. Its docker build repoints from the umbrella repo to
`ezagent-product` (§5.4).

### 2.1 Cross-cutting edges and how each is broken

1. **web → plugins (compile, router/endpoint atoms)** — *not broken; direction
   is already correct* (product sits on top). Cost: every plugin bump needs a
   product pin bump to reach a release — acceptable, that is the release train.
   Optional (later, not a precondition): the declarative route/socket manifest
   direction from `docs/superpowers/specs/2026-07-19-plugin-ui-surface-architecture-research.md`
   (VS Code-style "declaration = data, read by the host") would demote these to
   data and reduce product churn.
2. **web asset aliases reach `../ezagent_plugin_world/assets`** — broken in
   Phase 0: world's npm build becomes self-contained in the world app (own mix
   alias building into its own `priv/static`; product serves plugin statics
   from dep priv dirs, the standard Phoenix `Plug.Static`-from-dep pattern).
3. **socialware seeds for kanban/hello in web's priv** — data-only; move each
   seed package to its plugin repo, product aggregates at release build
   (Phase 0 item; keeps the existing `ManifestSeed.scan_all!` late-boot lane
   untouched).
4. **Cross-cluster test-only deps** (`feishu →(:test) cc`,
   `kb →(:test) codex`) — two options, per test: (a) relocate the test to the
   product integration suite (right home for cross-cluster behavior), or
   (b) keep as a test-env git dep (mix supports `only: :test` git deps). Default:
   (a).
5. **core → upper bare-atom IoC** (authority_loader, flavor maps, registries,
   `UniversalBehaviors`) — no compile edges (§1.2.4); survives split unchanged.
   The extraction's C5 pre-flight already inverts the two hard-coded module
   tables (`behavior_set.ex:328-349`, `kind_base_backfill.ex:100-116`) into
   registration data (spec §3.4 non-port findings), which is the same idiom.
6. **Umbrella-wide gates with cross-app path anchors** — re-homed per repo
   (§5.2); this is Phase 0 work, mechanical.

No proposed repo edge is cyclic: R0 ← R1 ← {R2, R3} and R1 ← R4, R2 ← R4,
{R0..R4} ← R5. The only would-be back-edges in today's code are the two
test-only deps in (4).

---

## 3. Cross-repo dependency mechanism

### 3.1 Options weighed for THIS project

| Mechanism | Pros here | Cons here |
|---|---|---|
| **Published Hex packages** (hex.pm) | Real semver resolution; release-friendly | Code is private; public hex.pm is out. Paid private orgs / infra overhead not justified at N=6 |
| **Self-hosted Hex mini-registry** (`mix hex.registry build`, static files behind the existing caddy on the deploy host) | Standard `~>` semantics; clean publish flow; umbrella children CAN publish (`{:dep, "~> x.y", in_umbrella: true}` dual form) | One more piece of infra to run; every cross-repo change needs publish+bump — slows the current dev loop where cross-repo changes are still common |
| **Git deps, tag/SHA-pinned** | Zero infra; native mix; SHA-pinned = reproducible (`mix.lock` records the SHA); matches the deploy-repo precedent; fastest to adopt mid-extraction | No version *ranges* (exact pins only); multi-app repos need `sparse:` + dual-mode dep declarations; diamond pins must be aligned by the top |
| **Monorepo-of-repos** (meta-repo with submodules + path deps) | Fastest edit loop across repos | As the *canonical* mechanism it defeats the purpose (blast radius returns); submodule ergonomics; CI still needs per-repo truth |

### 3.2 Recommendation: git deps as the standing mechanism, one helper as the seam

**Canonical: tag-pinned git deps.** Every cross-repo dep is declared through a
single helper used by every `mix.exs`:

```elixir
# each repo vendors this one file; apps `Code.require_file` it
defp ezagent_dep(app) do
  cond do
    umbrella_sibling?(app)          -> {app, in_umbrella: true}
    path = workspace_override(app)  -> {app, path: path}             # dev loop
    true                            -> {app, git: repo_url(app),     # canonical
                                        sparse: "apps/#{app}",
                                        tag: pinned_tag(app)}        # from deps.pins.exs
  end
end
```

- **Same-repo** deps stay `in_umbrella: true` (each repo remains a small
  umbrella — R1 keeps 12 apps, R2 keeps 6, etc.).
- **Cross-repo** deps use `git:` + `sparse: "apps/<app>"` (mix's sparse
  checkout of one app out of a multi-app repo) + a tag pinned in a per-repo
  `deps.pins.exs`. Because a sparse-fetched app's own `mix.exs` must resolve
  standalone, *every* app adopts the helper (Phase 0) — inside its home
  umbrella the helper emits `in_umbrella:`, when fetched as a dep it emits the
  git form for its lower-repo needs. A one-test gate per repo asserts all pins
  files agree.
- **The product repo is the diamond-resolver**: it declares every `ezagent_*`
  dep with `override: true` at its pinned tag, so inner pins can lag without
  conflicting — the product `mix.lock` (SHAs) is the single source of truth for
  what ships, exactly like today's single umbrella lock.
- **Dev loop**: a `ezagent-workspace` meta-repo (git submodules of all repos,
  side-by-side) plus `EZAGENT_WORKSPACE=1` flips the helper to path deps —
  cross-repo editing stays a one-machine experience. The workspace is a dev
  convenience, never a CI or release input.

**Versioning strategy**: every repo auto-tags `v0.<minor>.<patch>` on
merge-to-main (CI job; patch bump default). Pin roll-ups land in the product
repo as ordinary PRs ("bump platform v0.41.2 → v0.42.0") where the integration
suite runs against the new pin set — the cross-repo contract check happens at
exactly one place. During hot workstreams, bump cadence can be per-day; the
mechanics don't care.

**Explicit upgrade trigger to the Hex mini-registry**: when (a) more than ~2
consumer repos are chafing on pin roll-ups per week, or (b) `ezagent-actor` is
to be consumed outside the org. Until then the registry is not worth its ops
cost. The helper is the seam — switching a dep from git to hex form later is a
one-function change, not a repo migration.

---

## 4. Sequencing against the actor-framework extraction

Extraction status on `origin/main`: **C0–C3 landed** (#1546 gate + read
surface, #1548 PresenterCaps/EntityCaps, #1550 cold reads, #1561
KindRegistry/ReadyGate consumers). Outstanding: **C4** (spine PR, sequenced
with the #195 owner), **C5** (physical move creating `apps/ezagent_actor`),
**C6** (~45-file `get_slice` long tail), **C7** (flip + allowlist `[]`).

**Ordering rule (the one hard rule of this plan):**

> **No app leaves the umbrella while it still holds actor-boundary allowlist
> debt.** The `actor_internals_boundary_test` module-keyed allowlist (spec §4)
> is per-module and therefore per-app: an app's entries must be zero before
> its repo extraction. Cross-repo migration of a reach-in is 10× the cost of
> the same one-line fix in the umbrella.

Concrete sequence:

1. **C4 + C5 complete in-umbrella** (unchanged from the extraction spec).
   C5 creates `apps/ezagent_actor` with zero in-umbrella deps and the
   standalone-compile acceptance (§7.2) — the repo boundary's dress rehearsal.
2. **Phase 0 of this plan runs in parallel with C4–C7** (§6): dep helper,
   gate re-homing, asset/seed decoupling. None of it conflicts with the
   extraction (different files).
3. **R0 extraction happens after C5, ideally after C7.** After C5 the app
   physically exists and compiles standalone; C6/C7 shrink the *consumer-side*
   debt. Splitting R0 at C5 (before C7) is tolerable only because the boundary
   gate + allowlist keep enforcing from the platform side; but every remaining
   C6 item would then pin-bump against a foreign repo. Recommendation: **let
   C6/C7 finish first** — they are ratchet chores, not architecture, and
   origin/main is landing chunks at days-cadence.
4. **Plugin repos (R2–R4) wait for C6** for the same reason: C6's long tail
   spans 16 apps *including plugins* (spec §4.4: hello(5), and the
   `get_slice` caller census); extract a plugin repo mid-C6 and those PRs go
   cross-repo.
5. **The platform/product split (R1/R5) is last** and independent of the
   extraction entirely.

The extraction and the repo split are the *same* program at two scales: the
extraction builds a gated in-process boundary; the split promotes proven
boundaries to repo boundaries. Never promote an unproven one.

---

## 5. CI / gates / release implications

### 5.1 Per-repo CI shape

Each code repo gets the two-layer shape the umbrella already has, scaled down:

- **gate** (deterministic, dockerized via the existing `docker/ci-runner.sh` /
  `Dockerfile.ci` pattern, on the same self-hosted mac): compile
  `--warnings-as-errors --force`, format, the repo's own arch/invariant subset,
  its static scanners (§5.2).
- **suite**: the repo's test shards. Today's full-suite shard map transfers
  almost 1:1: `core`/`domain`/`session`/`static` shards → R1; the `plugin`
  shard splits across R2/R3/R4; `web`/`e2e` → R5. `ci_shard_parity_test`
  retires in favor of per-repo suites + the product integration run (its job —
  "no test silently dropped" — is inherited by each repo owning its whole
  suite).

Runner capacity: more pipelines but each strictly smaller; plugin-repo suites
are minutes-scale. Only R1 and R5 keep a heavyweight suite. The mac's
concurrency guidance in `ci.yml` (unpinned cpuset, `SCHEDULERS=8`) already
anticipates multiple concurrent gate runs.

### 5.2 The gates across repos — who owns which scanner

Today every gate is an umbrella-wide source scan. Post-split there are three
kinds, each with a different home:

1. **Contract-owner scanners (exported)** — gates that enforce a *lower* repo's
   boundary against *upper* code: the actor-internals boundary scan (spec §4),
   message-read/list-read/internal-reads chokepoints, spawn-chokepoint,
   cap-signing fail-loud chain. Each ships as a **library module in the repo
   that owns the contract** (R0 ships the actor scanner; R1 ships the
   chokepoint/cap scanners as part of `ezagent_core`'s package). Consumer repos
   invoke it in their own gate over their own `lib/` (`ArchCheck.run(paths)`);
   **allowlists live in the consumer repo** — the debt belongs to whoever holds
   it. This is the same "scanner is a module, test delegates to it" shape
   `check_invariants` #13 already uses.
2. **Repo-local ratchets** — `oversized_modules`, `doc.scan` counters,
   `arch.scan` baseline manifest: split the manifest per repo (the cross-app
   path anchors in `@def_count_files` / `@spawn_registry_sanctioned_files` /
   `@template_class_files` get re-homed to the repo owning each file — Phase 0,
   mechanical). Line-anchor drift risk is unchanged (known playbook).
3. **Whole-system gates** — `check_invariants` (boots the app),
   `ezagent.uri_query.scan`, socialware conformance, world fixtures check, the
   acyclic/undeclared-dep pair: run in **R5's integration pipeline against the
   full assembly**. Key mechanism: the product repo fetches every git dep's
   **full source** into `deps/`, so umbrella-wide AST scans keep working there
   over `deps/*/lib` + `apps/*/lib` — the union backstop. A violation that
   sneaks past a consumer repo's gate (stale scanner version, wrong allowlist)
   is still caught at the pin-bump PR in product.
   `undeclared_umbrella_dep_test` becomes *obsolete across repos* — mix's real
   dependency isolation replaces the build-order-masking heuristic (its very
   defect class, per its own moduledoc, disappears) — and is retained only
   inside each multi-app repo.

**Version-skew rule for exported scanners**: consumer repos run the scanner at
their *pinned* dep version; product runs it at the *bumped* version during
roll-up. A scanner-tightening release therefore surfaces new findings at the
product pin-bump PR, which then fans out fix-PRs to consumer repos — findings
never block a consumer repo's unrelated work.

### 5.3 Release

Operationally unchanged: **one OTP release, assembled by R5.** The root
`releases/0` explicit-applications list moves verbatim to the product repo
(mix releases may list dependency applications with start types; the "every
runnable app must be listed explicitly" rationale and the `ezagent_cli: :load`
entry carry over). `mix release ezagent` in product pulls all repos at
`mix.lock`-recorded SHAs → byte-reproducible input set.

### 5.4 Deploy flow

`ezagent-deploy` (canary/beta/stable on the mac) changes only its build
source: docker build context = an `ezagent-product` checkout; `mix deps.get`
inside the build now fetches git deps, so the deploy host build needs (a) git
credentials for the `ezagent42` repos and (b) the existing proxy env
(`HTTPS_PROXY` with the NO_PROXY carve-outs already required on the node).
Migration rehearsal/backup/reflow contracts are untouched — migrations still
live in one place (R1's `apps/ezagent_core/priv/repo/migrations`, delivered
into the release exactly as today).

---

## 6. Phased migration path

Every phase leaves the system releasable; every extraction is reversible by
re-vendoring the app dirs and flipping the dep helper back.

### Phase 0 — decouple in-umbrella (no repo changes; parallel with C4–C7)

0.1 Land this plan (review + owner sign-off on topology + mechanism).
0.2 Introduce `ezagent_dep/1` in all 28 `mix.exs` (pure refactor — emits
    `in_umbrella: true` for everything while in the umbrella; zero behavior
    change; one PR).
0.3 Re-home gate anchors: split `arch_baseline_manifest.exs` +
    `arch.scan` path-anchored lists per future repo; extract the
    contract-owner scanners into library modules (consumed by the same tests
    today — no CI behavior change yet).
0.4 Make world's asset build self-contained (kill the
    `cmd --cd ../ezagent_plugin_world/assets` reach-ins from web's aliases).
0.5 Move socialware seed packages to their plugin apps' priv; product-side
    aggregation step in the release assembly.
0.6 Relocate the two cross-cluster test-only deps' tests (feishu→cc,
    kb→codex) into the e2e/web shard (future product integration suite).
0.7 Per-future-repo standalone-build check in CI: for each planned repo's app
    set, `mix compile --warnings-as-errors` with only that set + lower sets on
    the path (generalizes the extraction's §7.2 acceptance; catches undeclared
    cross-cluster reach-ins *before* any repo exists).

**Gate to proceed**: 0.7 green for the R0 and R2–R4 app sets; extraction at
C5+ (for Phase 1: ideally C7).

### Phase 1 — extract `ezagent-actor` (R0)

1.1 `git filter-repo` the umbrella history to `apps/ezagent_actor/**` (+ its
    spec/docs paths) → new repo `ezagent42/ezagent-actor`; CI (gate + suite +
    auto-tag) stands up; tag `v0.1.0`.
1.2 Umbrella flips `ezagent_dep(:ezagent_actor)` to the git form; delete the
    vendored dir. `mix.lock` pins the SHA.
1.3 One full release + canary deploy cycle to prove the deploy-host git-fetch
    path (§5.4) on the smallest possible split.

### Phase 2 — extract the plugin clusters (R2 → R3 → R4, in that order)

Order: R2 first (R4 depends on it), R3 independent, R4 last. Per repo:
filter-repo the app set, stand up CI, flip the umbrella's web/`kb`-test deps
to git form, delete vendored dirs. After Phase 2 the umbrella contains
platform + web only. `Ezagent.Plugin.boot/1`'s declarative contract means no
boot-wiring changes at all — plugins register at start exactly as today
(§1.2.5); the release list is untouched.

### Phase 3 — split product from platform (R5 / R1)

The umbrella repo **becomes** `ezagent-platform` in place (least churn — it
keeps the largest history and the migrations dir). `ezagent_web` + release
def + integration suite + runtime config filter-repo OUT to
`ezagent42/ezagent-product`; deploy repoints to product; the platform repo's
full-suite shrinks to core/domain/session/static shards; e2e/web shards move
to product. GitHub required-check wiring moves with them.

### Phase 4 — optional, later, each with its own trigger

- Split R1 (identity/cap spine vs collaboration domains) — trigger: #195
  family fully landed + spine API stable behind the §3.4 ports.
- Per-plugin repos out of R2–R4 — trigger: a cluster repo's PR traffic shows
  sustained cross-team contention.
- `ezagent-actor` → self-hosted Hex registry / external publication (§3.2
  triggers).

### 6.1 Biggest risks (ranked)

1. **Cross-repo change amplification during hot workstreams.** A spine or
   session change that today is one PR becomes N pin-coordinated PRs if the
   boundary is drawn through an active seam. *Mitigation*: R1 keeps
   core+domains together; the §4 allowlist-zero rule; platform/product split
   last; the workspace path-override keeps multi-repo editing one-machine.
2. **Version skew / silent contract drift.** A consumer pins an old platform
   and misses a scanner or API tightening. *Mitigation*: product `override:
   true` pins + integration suite at every roll-up; exported-scanner
   version-skew rule (§5.2); auto-tag on every merge keeps pins cheap to
   advance.
3. **Gate blindness during the transition.** Between "scanner re-homed" and
   "repo extracted", a path-anchored gate could silently scan nothing.
   *Mitigation*: Phase 0.3 keeps the umbrella-wide tests delegating to the
   new library scanners (same coverage, new home) until each extraction; the
   product `deps/**` backstop (§5.2.3) exists from Phase 1 on; every scanner
   keeps its gate-has-teeth fixture self-test.
4. **Build/asset/seed coupling breaking the release.** The world-npm and
   socialware-seed reach-ins (§1.2.7) fail only at release build if missed.
   *Mitigation*: Phase 0.4/0.5 land before any extraction; Phase 1.3 forces a
   full canary cycle on the smallest split.
5. **History/tooling churn from filter-repo.** PR cross-links and
   line-anchored baselines (the known arch.scan drift class) break on rewrite.
   *Mitigation*: extraction keeps paths (`apps/<app>/…` stays the in-repo
   path, so blame/anchors survive); a `docs/repo-map.md` records
   old-repo→new-repo provenance per app.
6. **Test-fixture and test-support entanglement** (other apps' tests seeding
   state via framework/test helpers — the extraction's §6.6 `ActorCase`
   concern, generalized). *Mitigation*: each lower repo exports its test
   support as part of its package (`Ezagent.ActorCase` precedent); Phase 0.7's
   standalone builds compile test envs too.
7. **Deploy-host fetch fragility** (git+proxy on the mac runner).
   *Mitigation*: Phase 1.3 rehearsal; `mix.lock` SHAs make fetches cacheable;
   fallback documented (vendor deps tarball into the build context).

---

## 7. Acceptance (for the split program as a whole)

1. Each repo builds and gates **alone** (`mix compile --warnings-as-errors` +
   its gate suite, no sibling checkout present).
2. `ezagent-product` assembles the release from pinned SHAs; canary → beta →
   stable promotion runs unchanged through `ezagent-deploy`.
3. The union of per-repo suites + product integration ≥ today's
   `mix ci.local` coverage (shard-map audit, §5.1 — the `ci_shard_parity`
   discipline re-proven once at Phase 3).
4. Every boundary scanner runs in ≥2 places (owner repo self-test + product
   backstop) and its consumer-side allowlists are at their pre-split counts or
   lower.
5. A one-line change in a plugin cluster repo reaches canary via: cluster PR →
   auto-tag → product pin-bump PR → deploy. Measured end-to-end ≤ 1 day
   without human archaeology — the blast-radius/context win this plan exists
   for, made observable.
