# Dockerized dev/test environment + layered checkpointed E2E harness ("scenario 0") — Design

**Date:** 2026-06-04
**Author:** Claude (cc-openclaw session), co-designed with Allen
**Status:** Design — converged after codex adversarial-review (rounds 1–7); pending Allen approval
**Task:** #21 (promoted). Supersedes ad-hoc E2E on the shared dev node (see memory `feedback_e2e_in_docker_fresh_seed`).

---

## 1. Problem & Goal

ESR E2E has been validated by hand on a long-lived shared dev node (`/private/tmp/esr-impl`) whose `$EZAGENT_HOME` has accumulated years of state — stale snapshots, pre-rename keys, expired creds, dead relay builds. That accumulation both *causes* spurious failures and *tempts* one-off hacks (manual cred provisioning, token minting, ad-hoc restarts).

**Goal:** a clean, **isolated docker dev/test environment** that starts **blank**, in which **E2E scenarios themselves seed the data** step-by-step through the **real ingress / production paths**, with **checkpointed snapshot "layers"** and a **programmatic resume-resolver** so a partial scenario resumes from the right checkpoint instead of re-running everything. Determinism + isolation remove both the false failures and the hack incentive.

This is itself the foundational **E2E "scenario 0"**: bring up a blank env + bootstrap; its end-state is the base layer every other scenario builds on (docker-base-layer analogy).

## 2. Non-goals (YAGNI)

- **Production image (`mix release`)** — a later phase. This spec is dev/test only, running `mix phx.server`.
- **Multi-node / clustering / k8s.** Single container, single BEAM.
- **Automating the raw-Feishu network frame for the TRUE gate** — the final real `@mention` over the live WS stays a manual "live tier" (§7). Standard 3 (`feedback_esr_e2e_standards`) requires a real human Feishu interaction; we exercise everything *below* the WS decode programmatically but do not fake the network hop.
- **Porting every existing scenario** — only scenario 0 + scenario 34 (worked example) are in scope; the rest port incrementally.

## 3. Locked decisions (Allen, 2026-06-04) + codex-review refinements

| # | Decision |
|---|----------|
| Q1 | A/B/C in ONE spec; harness = E2E **scenario 0**; build order A→B→C. |
| Q2 | A snapshot **layer = tar of `$EZAGENT_HOME/<profile>` EXCLUDING credential files**. Restore = unpack + (re)provision creds + restart node (rehydrate). Docker isolates; layers are state tarballs, NOT docker images. |
| Q3 | Resolver = **chain hash** `fp(N)=hash(fp(N-1)+inputs_hash(step_N))`; `inputs_hash` = content-hash of the **full step contract** (`run`+`await`+`assert` ASTs) + its **declared dependency closure** `@layer_inputs` (helpers/prompts/fixtures). A layer is published **only after `assert` passes**; the resolver selects only `assert_passed` layers at the current `schema_version`. |
| Q4 | E2E drives programmatically. **Feishu-ingress steps inject at the real ingress boundary `EzagentPluginFeishu.InboundDispatcher`** (binding/mention/origin/presence/rehydrate/error); `Ezagent.Invocation.dispatch` only for lower-level domain setup. Two tiers: (1) programmatic, autonomous in docker; (2) raw Feishu WS frame + real human `@mention` as a manual "live tier". |

**Key design stance (codex r3–r7): secrets are never cached.** The earlier idea of capturing provisioned credentials inside layers spawned a cascade of time-sensitivity problems (expired cached creds selected, prefix-wide validity, source rotation). The clean resolution: **credential files are EXCLUDED from layers and always (re)provisioned on restore.** This removes credential time-sensitivity from the resolver entirely.

## 4. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ docker (dev/test image: elixir+otp + claude/codex/uv CLIs)   │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ BEAM: mix phx.server  (:10042)                         │ │
│  │   $EZAGENT_HOME/<profile>  ← swappable volume          │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
        ▲ stop → extract layer (no creds) → provision creds → start
        │
┌───────┴────────────────────────────────────────────────────┐
│ E2E harness (control process)                              │
│  • Scenario = ordered [Step]   (phase B)                    │
│  • Resolver: chain-hash → highest assert_passed layer       │
│  • LayerStore: tar(EZAGENT_HOME minus creds) + manifest     │
│  • Driver: InboundDispatcher (ingress) / Invocation (setup) │
│  • Restore provision-hook: refresh-if-expired creds         │
└─────────────────────────────────────────────────────────────┘
```

### 4.A — dev/test docker environment

**Already docker-friendly:** config is env-driven (`EZAGENT_HOME`/`EZAGENT_PROFILE` → SQLite path; `PORT` default 10042; dev binds `0.0.0.0`; `EZAGENT_PUBLIC_HOST/SCHEME/PORT`, `DATABASE_PATH`, `POOL_SIZE`). No config refactor needed.

Artifacts:
- **`docker/Dockerfile.dev`** — multi-stage: base `hexpm/elixir:1.19.<x>-erlang-28.<x>-debian-bookworm-<y>` (pin to the repo toolchain); install the CLIs agents shell out to (resolved via `System.find_executable/1`): **`claude`** (npm `@anthropic-ai/claude-code`, pinned), **`codex`** (pinned, 0.134.x), **`uv`** (for MCP bridge `uv run --script`), plus `git`, `tar`, `ca-certificates`, Node; then `mix deps.get` → `mix assets.setup` (esbuild/tailwind binaries) → `mix compile`.
- **`docker/docker-compose.dev.yml`** — one `esr` service (`mix phx.server`, `10042:10042`); env file (`PORT`, proxy `HTTP(S)_PROXY`+`NO_PROXY` feishu/localhost-direct, `EZAGENT_HOME=/data`, `EZAGENT_PROFILE`); volumes (below); endpoint healthcheck.
- **`docker/entrypoint.sh`** — blank `$EZAGENT_HOME/<profile>` → `mix ezagent.bootstrap`; then `mix phx.server`.
- **`docker/.dockerignore`** — exclude `_build`, `deps`, `node_modules`, `/private/tmp/esr-*`, `.git`.

**The dev env MUST support all three agent flavors — cc, codex, curl(deepseek)** (Allen 2026-06-04). They have different secret models, so credential handling is split by *kind of secret*, not one-size-fits-all:

**(i) Static secrets — read-only mount:** Feishu `feishu.yaml`, fixtures. Never rotated.

**(ii) Expiring OAuth sources (cc + codex) — durable mutable volume, PER FLAVOR, shared per profile/suite:** cc's `.credentials.json` and codex's `auth.json` are OAuth tokens that expire and rotate (single-use refresh). Each flavor's provisioner refreshes an *expired* source and **atomically writes the rotated token back**, so each source must be **writable + durable**: seeded from a read-only seed **only when absent** (first run), **never re-overwritten from the seed after rotation**. Each source's cross-process lock is **colocated** in its volume AND **crash-recoverable** — an **OS advisory lock on an open fd** (auto-released on process death) OR a lease with owner+mtime stale-lock recovery + fencing. (The current cc `provision/3` uses an `:exclusive` lockfile that is NOT crash-safe — the implementation MUST upgrade it; the codex provisioner is built crash-safe from the start.) **cc has its provisioner (#17 PR-E); the codex provisioner (`refresh_test_credentials/3` over CODEX_HOME `auth.json`) is implemented WITHIN #21** so codex is layerable too (see §4.B + PR list).

**(iii) Per-agent OAuth credential dirs (cc + codex) — NEVER in a layer:** provisioned from the per-flavor durable source into each agent's config dir; excluded from every layer tar (§4.C) and re-provisioned on restore (§4.B).

**(iv) curl's static deepseek API key — NOT an OAuth credential:** curl implements NONE of the `CredentialAdapter` callbacks; its key lives in the agent's `:api_keys` DB slice (set via the `put_api_key` action, read via `reads_siblings([:api_keys])`). It does not expire and is captured in the layer's DB tar. So curl needs **no provisioner and no exclusion**: a domain-setup step seeds the key via `put_api_key` from the read-only mounted test key, and it simply rides in the layer (a static test key — see residual on optional scrubbing). curl is layerable trivially.

**Deliverable (PR-1):** `docker compose -f docker/docker-compose.dev.yml up` → blank, bootstrapped ESR at `http://100.64.0.27:10042` (Tailscale, `feedback_remote_browser_ip`), Feishu WS connected.

### 4.B — scenario-as-steps framework

A **scenario** is an ordered list of named **steps**; each performs actions against the running ESR and may assert.

**Two step kinds (codex r1 finding 1):**
- **Domain-setup step** — `Ezagent.Invocation.dispatch` (inner domain chokepoint) for low-level seeding with no user-facing ingress: create users/agents, write templates, grant caps, define routing rules.
- **Ingress step** — represents "a user sends a Feishu message": constructs the **decoded Feishu event shape** and feeds it to the **real `EzagentPluginFeishu.InboundDispatcher`** (the boundary just below the WS/webhook decode), exercising sender-identity resolution, chat-binding disambiguation, presence, session rehydrate, attachment handling, `_feishu_origin` stamping, legend-aware mention parsing, and human-facing error reporting. Only the live WS frame + the real human remain to tier 2.

**Step shape & hashing (codex r1 finding 3 + r2 finding 1):**
- **`Ezagent.E2E.Step`** — `%Step{name, kind, inputs_hash, run, await, assert, cacheable?}`.
- **`defstep` macro** — captures the ASTs of **all three callbacks** (`run`, `await`, `assert`) + a declared dependency closure `@layer_inputs` (helper modules, prompt files, fixture paths). `inputs_hash = sha256(run_ast <> await_ast <> assert_ast <> hash_each(@layer_inputs))`. Hashing only `run` would let a tightened `await`/`assert` reuse a layer made under the weaker contract; an undeclared external dep is a lint error (CI greps callback bodies for known helper calls absent from `@layer_inputs`).

**Quiescence barrier (codex r2 finding 2):** ESR relay/model flows are **asynchronous** (multi-hop provider work completes after the call returns — why the live harness *polls*). A step declares **`await(ctx) -> :ok | {:error, pending}`** that must positively observe all expected durable outcomes (messages via `MessageStore`, bridge registrations, PTY/app-server health, no pending async) BEFORE any snapshot. Per-step order: **`run` → `await` → `assert` → (only if assert passes) atomically publish the layer.** `await` proves terminal *durable* state, not correctness; snapshotting before `assert` would cache a wrong-but-settled state a later resume could select and run past (false green). Failed `assert` discards the staged tar and flunks. The published manifest records `assert_passed: true` bound to the current `fp` + `schema_version`.

**Credentials are NOT step-cached output (codex r3–r7):** credential files (the union of `Ezagent.Agent.CredentialAdapter.credential_relpaths/0` across flavors — `#17 PR-A`) are **excluded from every layer tar**. On **every restore**, a mandatory **provision hook** runs BEFORE the node serves: for each agent the restored DB references, the flavor's `refresh_test_credentials/3` provisioner (cc → `CredentialRefresh.provision/3`, refresh-if-expired from the **per-flavor** durable source, §4.A) writes fresh creds into the per-agent config dir. So creds are never frozen into a checkpoint, never expire-in-a-layer, and the resolver never reasons about credential time-sensitivity. (`valid_on_restore?` is NOT needed for creds; YAGNI for other time-sensitive state until a need arises.)

**Layerability rule (codex r8 — contract totality) — all three flavors must be layerable (Allen):** a flavor is **layerable** iff every secret it uses is safe across a layer save/restore, by one of two routes:
- **(a) Expiring OAuth creds** (cc, codex): the secret is declared via `credential_relpaths`, **excluded** from the layer, and **re-provisionable** via `refresh_test_credentials/3`. cc has its provisioner (#17 PR-E); **codex's provisioner is implemented within #21** (CODEX_HOME `auth.json` refresh) so codex is layerable — NOT deferred.
- **(b) Static, non-expiring secrets** (curl's deepseek key): captured in the layer's DB (the `:api_keys` slice), seeded once via `put_api_key`; no provisioner/exclusion needed because there is no expiry.
- the harness runs a **fail-loud preflight** (`feedback_let_it_crash_no_workarounds`): before creating/restoring a layer, if a scenario references an **expiring-credential** flavor that lacks a provisioner, it **aborts up front with a clear message** — never silently starts an agent with missing auth. (This guards future flavors; cc/codex/curl all pass once the codex provisioner lands.)
- the **durable OAuth source is per-flavor** (cc source ≠ codex source); each maps to its own durable source volume + crash-safe lock (§4.A).

**ctx + manifest codec (codex r1 finding 4):** ctx threads through steps; restore restarts the node, so ctx is persisted in the manifest — but JSON-serializable is insufficient (`%URI{}`, `MapSet` caps, atom-keyed maps, `DateTime`, message structs don't round-trip). The manifest has a **versioned schema with primitive-only ctx** + explicit `encode/1`/`decode/1`: URIs as strings reloaded via `URI.new!/1`; caps rebuilt from durable principals (not stored); timestamps ISO8601; no atoms/PIDs. Steps may only put codec-supported types in ctx (lint-checked).

**Driver** — `mix ezagent.e2e.run <scenario> [--resume | --from-step N | --fresh]`: resolve start layer (§4.C) → restore (extract tar → **provision-hook creds** → start node, `decode` ctx) → run remaining steps (`run`→`await`→`assert`→publish) → report flunk-style with expected-vs-seen.

**Determinism note:** agent output is non-deterministic; assertions on agent content check structure/markers (e.g. `telephone_hop` wrapper, sender URI), not prose. A layer taken after a passing `assert` caches that run's concrete output (deterministic resume); a changed `inputs_hash` re-rolls.

**Deliverable (PR-2):** framework + **scenario 0** (blank → bootstrap → assert endpoint healthy → seed baseline admin user) runs top-to-bottom; its final layer is the base.

### 4.C — snapshot layers + resume-resolver

- **Layer** = `tar(EZAGENT_HOME/<profile>)` **with credential files excluded** (`--exclude` the `credential_relpaths` set) + sidecar `manifest.json` = `{schema_version, scenario_id, step_index, step_name, fp, assert_passed: true, ctx (codec-encoded)}`. A layer exists only if its step's `assert` passed (atomic post-assert publish), so a present layer is by construction a known-good, secret-free checkpoint.
- **Fingerprint chain:** `fp(-1) = sha256(scenario.base_fp <> env_image_id)`; `fp(N) = sha256(fp(N-1) <> step_N.inputs_hash)`. `env_image_id` (docker image digest) invalidates all layers when deps/CLIs change.
- **Resolver:** to run up to step T — compute `fp(0..T)`; pick the **highest M ≤ T** with a cached layer where `fp == fp(M)` AND `assert_passed` AND `schema_version == current`; restore it; run `M+1..T`. No qualifying layer → `base` (or blank) at step 0. **No silent reuse** — exact `fp` match with a recorded passing assertion only. (Because creds aren't in layers, there is no credential-expiry case for the resolver to handle — it is closed by construction, not by a validator.)
- **Invalidation:** any change in steps 0..K inputs — including a tightened `await`/`assert` (their ASTs are hashed) or a declared `@layer_inputs` helper/prompt/fixture — changes `fp(K..)` → layers ≥ K never match → recomputed.
- **Restore mechanism:** harness (control process) does: `docker compose stop esr` → wipe + extract layer tar into the `$EZAGENT_HOME` volume (no creds in it) → **run the credential provision-hook** (refresh-if-expired from durable source → per-agent dirs) → `docker compose start esr` → wait healthy. The node then **rehydrates Kinds from the restored DB/snapshots** — the cold-restart path hardened by #557 + PR-4. PTY subprocesses respawn on rehydrate/demand. Live-only state (PTY buffers, app-server sockets, in-flight PubSub, in-memory registries) is not in the tar by design — which is why layers are only taken at quiescent boundaries (§4.B).

**Deliverable (PR-3):** layer pack/unpack (with cred-exclude) + manifest codec + resolver + restore-with-provision orchestration + `--resume`/`--from-step`; demonstrated by re-running an unchanged-prefix scenario (skips to the right step) AND editing a helper (layers ≥ that step rejected).

## 5. Why the restore path is safe now

Restore = restart node + rehydrate from the restored `$EZAGENT_HOME` (+ freshly provisioned creds). The rehydrate path was hardened this cycle: PR-4 (state normalization, guard empty-over-good) + #557 (lazy-migrate legacy `claude_config_dir`). Layers are taken only at quiescent boundaries, so the tar holds settled durable state the rehydrate path is designed to restore.

## 6. Components & boundaries (for plan decomposition)

| Unit | Responsibility | Depends on |
|------|----------------|-----------|
| `docker/Dockerfile.dev`, `compose`, `entrypoint` | reproducible blank env | mix, CLIs |
| `Ezagent.E2E.Step` + `defstep` | one named, full-contract-hashed action + `await` | — |
| `Ezagent.E2E.Scenario` | ordered steps + base | Step |
| `Ezagent.E2E.Manifest` | versioned schema + ctx encode/decode | — |
| `Ezagent.E2E.LayerStore` | pack/unpack tar (cred-exclude) + manifest, lookup by fp | filesystem, Manifest, CredentialAdapter |
| `Ezagent.E2E.Resolver` | chain-hash → pick assert_passed start layer | LayerStore, Scenario |
| `Ezagent.E2E.EnvControl` | stop/start node + swap EZAGENT_HOME + provision-hook + wait healthy | docker compose, CredentialRefresh |
| ingress driver | feed decoded Feishu events to `InboundDispatcher` | ezagent_plugin_feishu |
| `mix ezagent.e2e.run` | wire driver + resolver + reporting | all above |

## 7. Two-tier observability

- **Tier 1 (programmatic, in docker, autonomous, CI-able):** ingress steps drive the **real `InboundDispatcher`** (binding/mention/origin/presence/rehydrate/error exercised), domain-setup steps use `Invocation.dispatch`; steps assert via the production read path (`Ezagent.MessageStore.recent_in_session/2`, registry/state queries) gated behind `await`. flunk on failure; never `assert true`.
- **Tier 2 (live, manual Feishu):** the resolver fast-forwards to the **last pre-trigger layer** (members seeded, rules wired, waiting for the `@mention`); a human sends the real `@传话游戏 <word>` over the live WS in the bound Feishu group; the harness polls the production read path for the `telephone_hop`-rendered round-trip (the existing `scenario_34_..._live_test.exs`). agent-browser screenshot = manual Standard-3 evidence. The ONLY tier-1↔tier-2 gap is the raw WS frame + the human.

## 8. Testing strategy (TDD)

Pure-logic units, test-first:
- **Resolver/LayerStore/Manifest:** chain-hash; highest-valid-layer selection; pack/unpack round-trip **with credential files excluded** (assert no `.credentials.json`/`auth.json` in the tar).
- **contract-hash invalidation** — tightening only `await` or `assert` (not `run`) rejects cached layers ≥ that step (r2 finding 1).
- **helper-change invalidation** — editing only a declared `@layer_inputs` helper rejects layers ≥ that step (r1 finding 3).
- **no-publish-before-assert** — a failing `assert` publishes NO layer; resolver never selects an `assert_passed=false`/absent layer (r2 finding 2).
- **post-restore decoded ctx** — a step runs against `decode`d ctx (URIs as `%URI{}`, caps rebuilt) after a simulated restart (r1 finding 4).
Credential provisioning (the source/lock thread):
- **restore re-provisions creds** — restoring a (cred-free) layer runs the provision-hook so per-agent dirs end up with valid creds (r3/r4 closed by construction).
- **expired-source recovery** — durable source starts expired → provision refreshes + writes back → succeeds (r5).
- **cross-run + concurrent rotation** — two sequential runs reuse the durable source (second sees the first's rotated token, not the seed); two concurrent runs serialize on the colocated lock without double-rotating (r6).
- **crash-recoverable lock** — a run killed mid-provision (stale lock) does NOT brick the next run: the advisory-fd lock auto-releases / the stale-lease policy recovers (r7).
- **non-layerable-flavor preflight** — a scenario/layer referencing an EXPIRING-credential flavor that lacks `refresh_test_credentials/3` is **rejected up front** with a clear error, never started with missing auth (r8). (cc/codex/curl all pass; the guard is for future flavors.)
- **all-three-flavor coverage** — the dev image + harness support cc, codex, AND curl(deepseek) agents end-to-end: cc+codex via exclude/provision, curl via in-DB static key (Allen requirement).
Integration: **scenario 0** (blank → healthy); **scenario 34** ported (tier-1 programmatic relay seed via domain-setup + ingress-via-`InboundDispatcher`, with `await` on the rendered round-trip; tier-2 manual Feishu hook). Every distinct bug → a fast regression test (`feedback_e2e_failure_earns_unit_test`).

## 9. Residuals (post-review, accepted)

1. **Restore = full node restart per layer hop** (seconds). Accepted: the win is skipping expensive step *re-execution* (agent spawns, model calls).
2. **`@layer_inputs` discipline** — correctness depends on steps declaring deps; the lint + `env_image_id` floor bound the blast radius. Accepted.
3. **Feishu raw-WS frame can't be faked for the TRUE gate** — tier 2 is explicitly manual; tier 1 covers everything below the decode.
4. **Layer store growth** — `--gc` (age/scenario-scoped) documented; not auto-GC in v1.
5. **Provision-on-every-restore cost** — a file copy + at most one OAuth refresh per restore; negligible vs. the node restart it accompanies. Accepted as the price of never caching secrets.
6. **curl's static deepseek key rides in the layer DB** — unlike cc/codex OAuth, curl's key is non-expiring state in the `:api_keys` slice, so it is captured in the layer tar. For a dev/test env with a dedicated test key this is acceptable; optional hardening (scrub the `:api_keys` slice from the tar + re-`put_api_key` on restore) is a documented future option, not v1. Accepted.
7. **codex provisioner is new code in #21** — codex was previously non-layerable (no provisioner); #21 now includes implementing `refresh_test_credentials/3` for codex (CODEX_HOME `auth.json` refresh), so all three flavors are layerable. This is in-scope work, not a deferral.

*(Resolved during review — folded into the design above: r1 ingress-via-InboundDispatcher + full-contract hash + ctx codec; r2 await-barrier + post-assert publish; r3–r7 the "secrets are never cached" stance, durable seed-once source, crash-recoverable colocated lock.)*

## 10. PR decomposition (hand-off to writing-plans)

- **PR-1 (A):** `Dockerfile.dev` + `compose.dev` + `entrypoint` + three credential stores (static RO mount, durable seed-once OAuth source w/ crash-safe lock, per-agent dirs) → `compose up` healthy.
- **PR-2 (B):** `Step`/`defstep`(full-contract hash + `@layer_inputs`)/`Scenario`/`Manifest` codec + `await` barrier + ingress-driver (`InboundDispatcher`) + `mix ezagent.e2e.run` + **scenario 0**.
- **PR-2b (codex provisioner):** implement codex `refresh_test_credentials/3` (CODEX_HOME `auth.json` refresh + crash-safe durable source), so codex joins cc as layerable (Allen: all three flavors). Mirrors cc's `CredentialRefresh`.
- **PR-3 (C):** `LayerStore` (cred-exclude per `credential_relpaths`) + `Resolver` + `EnvControl` (restore + per-flavor provision-hook + curl `put_api_key` seed) + layerability preflight + `--resume`/`--from-step`; resume-skip + helper-invalidation + crash-safe-lock + all-three-flavor restore demonstrated.
- **PR-4 (follow-on):** port scenario 34 (relay) as the worked example — exercises cc→codex→curl all three layerable — incl. the tier-2 live hook.

## 11. Bilingual

Per `feedback_bilingual_docs_convention`, a `…-design.zh_cn.md` mirror is created before the final Allen confirmation; the Chinese summary is sent via Feishu.

## 12. Cross-references

- Cold-restart rehydration: PR-4, #557; memory `project_scenario34_e2e_bug_stack`.
- Credential contract + provisioner: `Ezagent.Agent.CredentialAdapter.credential_relpaths/0` (#17 PR-A), `EzagentPluginCc.CredentialRefresh.provision/3` (#17 PR-E).
- Feishu ingress: `EzagentPluginFeishu.InboundDispatcher`, `webhook_plug.ex`, `ws_client.ex`.
- Scenario-34 doc + live harness: `docs/scenarios/34-sender-locked-relay/scenario.md`, `apps/ezagent_domain_chat/test/e2e/scenario_34_sender_locked_relay_live_test.exs`.
- phx-restart-rebuild prior art: `apps/ezagent_core/test/e2e/scenario_25_phx_restart_rebuild_test.exs`.
- Bootstrap/home: `mix ezagent.bootstrap`, `mix ezagent.home.init`.
- Standards: `feedback_e2e_in_docker_fresh_seed`, `feedback_e2e_faces_production`, `feedback_esr_e2e_standards`, `feedback_self_generate_test_credentials`, `feedback_remote_browser_ip`, `feedback_spec_codex_adversarial_review`.
