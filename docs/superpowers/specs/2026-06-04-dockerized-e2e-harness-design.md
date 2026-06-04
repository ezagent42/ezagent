# Dockerized dev/test environment + layered checkpointed E2E harness ("scenario 0") — Design

**Date:** 2026-06-04
**Author:** Claude (cc-openclaw session), co-designed with Allen
**Status:** Design — revised after codex adversarial-review (rounds 1 + 2); pending Allen approval
**Task:** #21 (promoted). Supersedes ad-hoc E2E on the shared dev node (see memory `feedback_e2e_in_docker_fresh_seed`).

---

## 1. Problem & Goal

ESR E2E has been validated by hand on a long-lived shared dev node (`/private/tmp/esr-impl`) whose `$EZAGENT_HOME` has accumulated years of state — stale snapshots, pre-rename keys, expired creds, dead relay builds. That accumulation both *causes* spurious failures and *tempts* one-off hacks (manual cred provisioning, token minting, ad-hoc restarts).

**Goal:** a clean, **isolated docker dev/test environment** that starts **blank**, in which **E2E scenarios themselves seed the data** step-by-step through the **real ingress / production paths**, with **checkpointed snapshot "layers"** and a **programmatic resume-resolver** so a partial scenario resumes from the right checkpoint instead of re-running everything. Determinism + isolation remove both the false failures and the hack incentive.

This is itself the foundational **E2E "scenario 0"**: bring up a blank env + bootstrap; its end-state is the base layer every other scenario builds on (docker-base-layer analogy).

## 2. Non-goals (YAGNI)

- **Production image (`mix release`)** — a later phase. This spec is dev/test only, running `mix phx.server`.
- **Multi-node / clustering / k8s.** Single container, single BEAM.
- **Automating the raw-Feishu network frame for the TRUE gate** — the final real `@mention` over the live WS stays a manual "live tier" (§7). Standard 3 (`feedback_esr_e2e_standards`) requires a real human Feishu interaction; we do not fake the network hop. (We DO exercise everything downstream of the WS decode programmatically — see §4.B / finding-1 fix.)
- **Porting every existing scenario** in this spec — only scenario 0 + scenario 34 (the worked example) are in scope; the rest port incrementally as follow-ons.

## 3. Locked decisions (Allen, 2026-06-04) + codex-review revisions

| # | Decision |
|---|----------|
| Q1 | A/B/C in ONE spec; harness = E2E **scenario 0**; build order A→B→C. |
| Q2 | A snapshot **layer = tar of `$EZAGENT_HOME/<profile>`**. Restore = unpack + restart node (rehydrate). Docker isolates; layers are state tarballs, NOT docker images. |
| Q3 | Resolver = **chain hash** `fp(N)=hash(fp(N-1)+inputs_hash(step_N))`; layer "after step N" valid iff steps 0..N **and their declared input closure** unchanged. **Revised (codex r1 finding 3):** the per-step hash covers the step's **declared dependency closure** (helpers/prompts/fixtures), not just the body. **Revised (codex r2 finding 1):** `inputs_hash` covers the **full executable step contract** — `run` + `await` + `assert` ASTs, not just `run` — so tightening a barrier or assertion invalidates the layer. **Revised (codex r2 finding 2):** a layer is published **only after `assert` passes**, and the resolver selects only `assert_passed` layers. |
| Q4 | E2E drives programmatically. **Revised (codex finding 1):** Feishu-ingress steps inject at the real ingress boundary **`EzagentPluginFeishu.InboundDispatcher`** (exercising binding/mention/origin/presence/rehydrate/error-reporting); `Ezagent.Invocation.dispatch` is used ONLY for lower-level domain setup, and is the inner chokepoint — NOT the user-facing path. Two tiers: (1) programmatic via InboundDispatcher, autonomous in docker; (2) the raw Feishu WS frame + real human `@mention` as a manual "live tier" on top. |

## 4. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ docker (dev/test image: elixir+otp + claude/codex/uv CLIs)   │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ BEAM: mix phx.server  (:10042)                         │ │
│  │   $EZAGENT_HOME/<profile>  ← swappable volume          │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
        ▲ stop/start + swap EZAGENT_HOME (restore a layer)
        │
┌───────┴────────────────────────────────────────────────────┐
│ E2E harness (runs on host / control process)               │
│  • Scenario = ordered [Step]   (phase B)                    │
│  • Resolver: chain-hash → pick highest valid layer          │
│  • Layer store: tar(EZAGENT_HOME) + manifest.json   (phase C)│
│  • Driver: InboundDispatcher (ingress) / Invocation (setup) │
└─────────────────────────────────────────────────────────────┘
```

Three components, built in order:

### 4.A — dev/test docker environment

**Already docker-friendly:** config is env-driven (`EZAGENT_HOME`/`EZAGENT_PROFILE` → SQLite path; `PORT` default 10042; dev binds `0.0.0.0`; `EZAGENT_PUBLIC_HOST/SCHEME/PORT`, `DATABASE_PATH`, `POOL_SIZE`). No config refactor needed.

Artifacts:
- **`docker/Dockerfile.dev`** — multi-stage:
  - base `hexpm/elixir:1.19.<x>-erlang-28.<x>-debian-bookworm-<y>` (pin exact versions to the repo's toolchain).
  - install runtime CLIs the agents shell out to (resolved via `System.find_executable/1`): **`claude`** (npm `@anthropic-ai/claude-code`, pinned), **`codex`** (pinned to the version ESR targets — 0.134.x per memory), **`uv`** (astral, for MCP bridge `uv run --script`). Plus `git`, `tar`, `ca-certificates`, Node (for the claude npm pkg).
  - `mix deps.get` → `mix assets.setup` (downloads standalone esbuild/tailwind binaries) → `mix compile`. (dev runs `mix phx.server`; assets compile at runtime, so `assets.setup` must be present.)
- **`docker/docker-compose.dev.yml`** — one `esr` service: `mix phx.server`; ports `10042:10042`; env file (`PORT`, proxy `HTTP(S)_PROXY`+`NO_PROXY` for feishu/localhost direct, `EZAGENT_HOME=/data`, `EZAGENT_PROFILE`); volumes: a **named volume for `$EZAGENT_HOME`** (the swappable state) + a **read-only secrets mount** (Feishu `feishu.yaml`; a claude/codex source credential for the provisioner); healthcheck hitting the endpoint.
- **`docker/entrypoint.sh`** — if `$EZAGENT_HOME/<profile>` is blank, run `mix ezagent.bootstrap` (home.init + adopt_db + ecto.migrate + health-check); then exec `mix phx.server`.
- **`docker/.dockerignore`** — exclude `_build`, `deps`, `node_modules`, the `/private/tmp/esr-*` worktrees, `.git`.

**Creds:** the image NEVER bakes credentials. Feishu creds + a claude/codex source login arrive via the read-only secrets mount; per-agent creds are provisioned during scenario steps by the existing `EzagentPluginCc.CredentialRefresh.provision/3` (PR-E) (and the codex analogue) — refresh-if-expired + copy into the per-agent config dir. (`feedback_self_generate_test_credentials`.)

**Deliverable (PR-1):** `docker compose -f docker/docker-compose.dev.yml up` → a blank, bootstrapped ESR reachable at `http://100.64.0.27:10042` (Tailscale, `feedback_remote_browser_ip`), Feishu WS connected.

### 4.B — scenario-as-steps framework

A **scenario** is an ordered list of named **steps**; each step performs actions against the running ESR and may assert.

**Two step kinds (codex finding 1):**
- **Domain-setup step** — uses `Ezagent.Invocation.dispatch` (the inner domain chokepoint) for low-level seeding that has no user-facing ingress: create users/agents, write templates, grant caps, define routing rules. This is legitimate for setup that a human would do via admin/CLI, not via a chat message.
- **Ingress step** — represents "a user sends a Feishu message." It constructs the **decoded Feishu event shape** and feeds it to the **real ingress dispatcher `EzagentPluginFeishu.InboundDispatcher`** (the boundary just below the WS/webhook decode). This exercises sender-identity resolution, chat-binding disambiguation, presence, session rehydrate, attachment handling, `_feishu_origin` stamping, legend-aware mention parsing, and human-facing error reporting — everything the real path does except the raw network frame. Only the live WS frame + the actual human remain to tier 2.

**Step shape & hashing:**
- **`Ezagent.E2E.Step`** — `%Step{name, kind, inputs_hash, run, await, assert, cacheable?}`.
- **`defstep` macro** — captures the ASTs of **all three callbacks** (`run`, `await`, `assert`) AND a **declared dependency closure** `@layer_inputs` (helper modules, prompt files, fixture paths the step relies on). `inputs_hash = sha256(Macro.to_string(run_ast) <> Macro.to_string(await_ast) <> Macro.to_string(assert_ast) <> hash_each(@layer_inputs))`. **Revised (codex r1 finding 3):** hashing the body alone silently misses helper/prompt/fixture changes; the explicit declared closure closes that. **Revised (codex r2 finding 1):** hashing only `run` would let a tightened `await`/`assert` reuse a layer made under the weaker contract — so all three callbacks are in the key. Steps with un-declared external dependencies are a lint error (a CI check greps the callback bodies for calls to known helper modules not listed in `@layer_inputs`).
- **`Ezagent.E2E.Scenario`** — `%Scenario{id, base, steps}`. `base` names a prerequisite scenario whose final layer is the starting point (scenario 0's base = blank).

**Quiescence barrier before snapshot (codex finding 2):**
- ESR relay/model flows are **asynchronous** (multi-hop provider work completes after the triggering call returns — which is why the live harness *polls*). A step therefore declares **`await(ctx) -> :ok | {:error, pending}`**: it must positively observe all expected durable outcomes (messages landed via `MessageStore`, bridge registrations present, PTY/app-server health, no pending async work) BEFORE the driver snapshots.
- A step that triggers live async work is `cacheable?: false` until its `await` confirms terminal state; the driver refuses to snapshot a step whose `await` has not returned `:ok`. This prevents freezing partial state into a layer and then restarting the async work away.

**ctx + manifest codec (codex finding 4):**
- `ctx` is threaded through steps. Because restore restarts the node (in-memory ctx is lost), ctx is persisted in the layer manifest — but **JSON-serializable is not enough** in this codebase (`%URI{}`, `MapSet` caps, atom-keyed maps, `DateTime`, message structs don't round-trip). The manifest has a **versioned schema with primitive-only ctx fields** + **explicit `encode/1` and `decode/1`**: URIs stored as strings and reloaded with `URI.new!/1`; caps NOT stored but rebuilt from durable principals on load; timestamps as ISO8601; no atoms/PIDs. Steps may only put codec-supported types in ctx (lint-checked).

**Driver** — `mix ezagent.e2e.run <scenario> [--resume | --from-step N | --fresh]`: resolve the start layer (§4.C), restore it (extract tar + `decode` ctx), run remaining steps, report flunk-style with expected-vs-seen. **Per-step order (codex r2 finding 2): `run` → `await` → `assert` → (only if assert passes) atomically publish the layer.** `await` proves terminal *durable* state but NOT correctness; snapshotting before `assert` would cache a wrong-but-settled state that a later resume could select and run past, skipping the failed step (false green). So a staged layer is published ONLY after `assert` returns `:ok`; on assert failure the staged tar is discarded and the run flunks. The published manifest records `assert_passed: true` bound to the current `fp` + `schema_version`.

**Determinism note:** agent (claude/codex) output is non-deterministic. Step **assertions on agent content** check structure/markers (e.g. the `telephone_hop` wrapper, a sender URI), not exact prose. A snapshot taken after a step whose `await` confirmed terminal state caches that run's concrete output, so resuming is deterministic; re-executing a model step (because its `inputs_hash` changed) re-rolls — acceptable.

**Deliverable (PR-2):** the framework + **scenario 0** (blank → bootstrap → assert endpoint healthy → seed baseline admin user) runs top-to-bottom; its final layer is the base.

### 4.C — snapshot layers + resume-resolver

- **Layer** = `tar(EZAGENT_HOME/<profile>)` + sidecar `manifest.json` = `{schema_version, scenario_id, step_index, step_name, fp, assert_passed: true, ctx (codec-encoded)}`. Stored in a layer-cache dir (its own volume/host dir), keyed/named by `fp`. A layer file only exists if its step's `assert` passed (the driver publishes atomically post-assert), so a present layer is by construction a known-good checkpoint.
- **Fingerprint chain:** `fp(-1) = sha256(scenario.base_fp <> env_image_id)`; `fp(N) = sha256(fp(N-1) <> step_N.inputs_hash)`. `env_image_id` (the docker image digest) invalidates all layers when deps/CLIs change. `inputs_hash` includes the declared dependency closure (§4.B).
- **Resolver:** to run scenario up to target step T — compute `fp(0..T)`; find the **highest M ≤ T** with a cached layer whose `fp == fp(M)` **AND `assert_passed == true` AND `schema_version == current`**; restore it (extract tar + `decode` ctx); run steps `M+1..T`. No qualifying layer → start from `base` (or blank) at step 0.
- **Invalidation:** if any input in steps 0..K changes — including a tightened `await`/`assert` (their ASTs are in `inputs_hash`) — `fp(K..)` change → cached layers ≥ K never match → recomputed. **No silent reuse**: a layer is used only on exact `fp` match with a recorded passing assertion under the current schema. Stale or assertion-less layers are never selected (optional age/scenario-scoped GC via `--gc`).
- **Restore mechanism:** the harness (control process, outside the BEAM) does: `docker compose stop esr` → wipe + extract layer tar into the `$EZAGENT_HOME` named volume → `docker compose start esr` → wait healthy. The node then **rehydrates Kinds from the restored DB/snapshots** — the cold-restart path, made solid by #557 + PR-4. PTY subprocesses (claude/codex) respawn on rehydrate/demand; **live-only state (PTY buffers, app-server sockets, PubSub in-flight, in-memory registries) is NOT in the tar by design** — which is exactly why the `await` quiescence barrier (§4.B) must drive every live effect to a *durable* terminal state before a layer is taken. A layer is only ever taken at a quiescent boundary.

**Deliverable (PR-3):** layer pack/unpack + manifest codec + resolver + restore orchestration + `--resume`/`--from-step`; demonstrated by re-running an unchanged-prefix scenario and observing it skip to the right step, AND by editing a helper to observe ≥-that-step layers rejected.

## 5. Why the restore path is safe now

Restoring a layer = restart node + rehydrate from the restored `$EZAGENT_HOME`. This is exactly the cold-restart rehydration path hardened this cycle: PR-4 (state normalization, guard empty-over-good snapshot) + #557 (lazy-migrate legacy `claude_config_dir`). Layers are only taken at quiescent boundaries (§4.B), so what the tar captures is the settled durable state the rehydrate path is designed to restore.

## 6. Components & boundaries (for plan decomposition)

| Unit | Responsibility | Depends on |
|------|----------------|-----------|
| `docker/Dockerfile.dev`, `compose`, `entrypoint` | reproducible blank env | mix, CLIs |
| `Ezagent.E2E.Step` + `defstep` | one named, input-hashed action + `await` barrier | — |
| `Ezagent.E2E.Scenario` | ordered steps + base | Step |
| `Ezagent.E2E.Manifest` | versioned schema + ctx encode/decode | — |
| `Ezagent.E2E.LayerStore` | pack/unpack tar + manifest, lookup by fp | filesystem, Manifest |
| `Ezagent.E2E.Resolver` | chain-hash → pick start layer | LayerStore, Scenario |
| `Ezagent.E2E.EnvControl` | stop/start node + swap EZAGENT_HOME + wait healthy | docker compose |
| ingress driver | feed decoded Feishu events to `InboundDispatcher` | ezagent_plugin_feishu |
| `mix ezagent.e2e.run` | wire driver + resolver + reporting | all above |

## 7. Two-tier observability

- **Tier 1 (programmatic, in docker, autonomous, CI-able):** ingress steps drive the **real `InboundDispatcher`** (so binding/mention/origin/presence/rehydrate/error logic IS exercised), domain-setup steps use `Invocation.dispatch`; steps assert via the production read path (`Ezagent.MessageStore.recent_in_session/2`, registry/state queries) gated behind the `await` barrier. flunk on failure; never `assert true`.
- **Tier 2 (live, manual Feishu):** the resolver fast-forwards to the **last pre-trigger layer** (members seeded, rules wired, waiting for the `@mention`); a human sends the real `@传话游戏 <word>` over the live WS in the bound Feishu group and observes; the harness polls the production read path for the `telephone_hop`-rendered round-trip (the existing `scenario_34_..._live_test.exs` already does this). agent-browser screenshot = manual Standard-3 evidence. Because the resolver jumps straight to the pre-trigger layer, the human step is quick + repeatable (no full re-seed). The ONLY gap between tier 1 and tier 2 is the raw WS network frame + the human — everything below the decode is covered by tier 1.

## 8. Testing strategy (TDD)

- **Resolver/LayerStore/Manifest unit tests** (highest-value pure logic), written test-first:
  - chain-hash computation; highest-valid-layer selection; pack/unpack round-trip.
  - **helper-change invalidation** — editing only a declared `@layer_inputs` helper rejects cached layers ≥ that step (codex finding 3 regression).
  - **post-restore decoded ctx** — a step runs against `decode`d ctx (URIs as `%URI{}`, caps rebuilt) after a simulated restart, not just manifest round-trip (codex finding 4 regression).
  - **no-snapshot-before-quiescence** — the driver refuses to snapshot when `await` returns `{:error, pending}` (codex r1 finding 2 regression).
  - **no-publish-before-assert** — a step whose `assert` fails publishes NO layer (staged tar discarded); the resolver never selects an assertion-less/`assert_passed=false` layer (codex r2 finding 2 regression).
  - **contract-hash invalidation** — tightening only the `await` or `assert` callback (not `run`) changes `inputs_hash`, so cached layers ≥ that step are rejected (codex r2 finding 1 regression).
- **Scenario 0** is the first integration target (blank → healthy).
- **Scenario 34** ported as the worked example (PR-4/follow-on): tier-1 seeds the relay team (domain-setup steps) + drives the trigger through `InboundDispatcher` (ingress step) with an `await` on the rendered round-trip; tier-2 manual Feishu hook for the TRUE gate.
- Every distinct bug found gets a fast regression test (`feedback_e2e_failure_earns_unit_test`).

## 9. Risks / residuals (post-review)

1. **Restore = full node restart per layer hop** (seconds each). Accepted: the win is skipping expensive step *re-execution* (agent spawns, model calls), not avoiding a BEAM reboot.
2. ~~Snapshots freeze in-flight async state~~ — **resolved**: `await` quiescence barrier; async steps non-cacheable until terminal durable state observed; layers only taken at quiescent boundaries (§4.B/§4.C).
3. ~~Source-hash ignores helper changes~~ — **resolved**: `inputs_hash` covers a declared dependency closure (`@layer_inputs`); lint catches undeclared deps; regression test (§8).
4. ~~ctx JSON has no codec~~ — **resolved**: versioned manifest schema, primitive-only ctx, explicit encode/decode, caps rebuilt from principals; regression test (§8).
5. ~~Invocation.dispatch ≠ production ingress~~ — **resolved**: ingress steps drive `InboundDispatcher`; `Invocation.dispatch` reserved for domain setup; the claim is narrowed (§4.B/§7).
6. **Feishu raw-WS frame can't be faked for the TRUE gate** — accepted; tier 2 is explicitly manual; tier 1 covers everything below the decode.
7. **Layer store growth** — many scenarios × steps = many tarballs; `--gc` (age/scenario-scoped) documented; not auto-GC in v1.
8. **`@layer_inputs` discipline** — correctness now depends on steps declaring their deps; mitigated by the lint check, but a determined author can still under-declare. Accepted residual (the lint + the `env_image_id` floor bound the blast radius).
9. ~~Fingerprint excludes await/assert~~ — **resolved**: `inputs_hash` covers the full `run`+`await`+`assert` contract (§4.B, Q3).
10. ~~Snapshot before assert → known-bad reusable checkpoint~~ — **resolved**: per-step order is `run`→`await`→`assert`→atomic publish; failed assert discards the staged layer; resolver selects only `assert_passed` layers (§4.B/§4.C).

## 10. PR decomposition (hand-off to writing-plans)

- **PR-1 (A):** `Dockerfile.dev` + `compose.dev` + `entrypoint` + blank-bootstrap → `compose up` healthy.
- **PR-2 (B):** `Step`/`defstep`(+`@layer_inputs`)/`Scenario`/`Manifest` codec + `await` barrier + ingress-driver (`InboundDispatcher`) + `mix ezagent.e2e.run` + **scenario 0** running top-to-bottom.
- **PR-3 (C):** `LayerStore` + `Resolver` + `EnvControl` + `--resume`/`--from-step`; resume-skip + helper-invalidation demonstrated.
- **PR-4 (follow-on):** port scenario 34 (relay) as the worked example incl. the tier-2 live hook.

## 11. Bilingual

Per `feedback_bilingual_docs_convention`, a `…-design.zh_cn.md` mirror will be created before the final Allen confirmation; the Chinese summary is what gets sent via Feishu.

## 12. Cross-references

- Cold-restart rehydration: PR-4, #557; memory `project_scenario34_e2e_bug_stack`.
- Feishu ingress: `EzagentPluginFeishu.InboundDispatcher`, `webhook_plug.ex`, `ws_client.ex`.
- Scenario-34 doc + live harness: `docs/scenarios/34-sender-locked-relay/scenario.md`, `apps/ezagent_domain_chat/test/e2e/scenario_34_sender_locked_relay_live_test.exs`.
- phx-restart-rebuild prior art: `apps/ezagent_core/test/e2e/scenario_25_phx_restart_rebuild_test.exs`.
- Bootstrap/home: `mix ezagent.bootstrap`, `mix ezagent.home.init`.
- Standards: `feedback_e2e_in_docker_fresh_seed`, `feedback_e2e_faces_production`, `feedback_esr_e2e_standards`, `feedback_self_generate_test_credentials`, `feedback_remote_browser_ip`, `feedback_spec_codex_adversarial_review`.
