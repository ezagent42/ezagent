# Dockerized dev/test environment + layered checkpointed E2E harness ("scenario 0") — Design

**Date:** 2026-06-04
**Author:** Claude (cc-openclaw session), co-designed with Allen
**Status:** Design — pending codex adversarial-review + Allen approval
**Task:** #21 (promoted). Supersedes ad-hoc E2E on the shared dev node (see memory `feedback_e2e_in_docker_fresh_seed`).

---

## 1. Problem & Goal

ESR E2E has been validated by hand on a long-lived shared dev node (`/private/tmp/esr-impl`) whose `$EZAGENT_HOME` has accumulated years of state — stale snapshots, pre-rename keys, expired creds, dead relay builds. That accumulation both *causes* spurious failures and *tempts* one-off hacks (manual cred provisioning, token minting, ad-hoc restarts).

**Goal:** a clean, **isolated docker dev/test environment** that starts **blank**, in which **E2E scenarios themselves seed the data** step-by-step through the **production invocation path**, with **checkpointed snapshot "layers"** and a **programmatic resume-resolver** so a partial scenario resumes from the right checkpoint instead of re-running everything. Determinism + isolation remove both the false failures and the hack incentive.

This is itself the foundational **E2E "scenario 0"**: bring up a blank env + bootstrap; its end-state is the base layer every other scenario builds on (docker-base-layer analogy).

## 2. Non-goals (YAGNI)

- **Production image (`mix release`)** — a later phase. This spec is dev/test only, running `mix phx.server`.
- **Multi-node / clustering / k8s.** Single container, single BEAM.
- **Automating the real-Feishu inbound** — the final `@mention` round-trip stays a manual "live tier" (§7). Standard 3 (`feedback_esr_e2e_standards`) requires a real human Feishu interaction; we do not fake it.
- **Porting every existing scenario** in this spec — only scenario 0 + scenario 34 (the worked example) are in scope; the rest port incrementally as follow-ons.

## 3. Locked decisions (Allen, 2026-06-04)

| # | Decision |
|---|----------|
| Q1 | A/B/C in ONE spec; harness = E2E **scenario 0**; build order A→B→C. |
| Q2 | A snapshot **layer = tar of `$EZAGENT_HOME/<profile>`**. Restore = unpack + restart node (rehydrate). Docker isolates; layers are state tarballs, NOT docker images. |
| Q3 | Resolver = **chain hash** `fp(N)=hash(fp(N-1)+source_hash(step_N))`; layer "after step N" valid iff steps 0..N unchanged. Step fingerprint = **content-hash of the step's source** (automatic invalidation). |
| Q4 | E2E drives **fully programmatically via `Ezagent.Invocation.dispatch`** (production path). Two tiers: (1) programmatic, autonomous in docker, asserts via production read path; (2) real-Feishu `@mention` as a manual "live tier" on top. |

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
│  • Driver: Invocation.dispatch (programmatic tier)         │
└─────────────────────────────────────────────────────────────┘
```

Three components, built in order:

### 4.A — dev/test docker environment

**Already docker-friendly:** config is env-driven (`EZAGENT_HOME`/`EZAGENT_PROFILE` → SQLite path; `PORT` default 10042; dev binds `0.0.0.0`; `EZAGENT_PUBLIC_HOST/SCHEME/PORT`, `DATABASE_PATH`, `POOL_SIZE`). No config refactor needed.

Artifacts:
- **`docker/Dockerfile.dev`** — multi-stage:
  - base `hexpm/elixir:1.19.<x>-erlang-28.<x>-debian-bookworm-<y>` (pin exact versions to the repo's `.tool-versions`/mix).
  - install runtime CLIs the agents shell out to (resolved via `System.find_executable/1`): **`claude`** (npm `@anthropic-ai/claude-code`, pinned), **`codex`** (pinned to the version ESR targets — 0.134.x per memory), **`uv`** (astral, for MCP bridge `uv run --script`). Plus `git`, `tar`, `ca-certificates`, Node (for the claude npm pkg).
  - `mix deps.get` → `mix assets.setup` (downloads standalone esbuild/tailwind binaries) → `mix compile`. (dev runs `mix phx.server`; assets compile at runtime, so `assets.setup` must be present.)
- **`docker/docker-compose.dev.yml`** — one `esr` service: `mix phx.server`; ports `10042:10042`; env file (`PORT`, proxy `HTTP(S)_PROXY`+`NO_PROXY` for feishu/localhost direct, `EZAGENT_HOME=/data`, `EZAGENT_PROFILE`); volumes: a **named volume for `$EZAGENT_HOME`** (the swappable state) + a **read-only secrets mount** (Feishu `feishu.yaml`; a claude/codex source credential for the PR-E provisioner); healthcheck hitting the endpoint.
- **`docker/entrypoint.sh`** — if `$EZAGENT_HOME/<profile>` is blank, run `mix ezagent.bootstrap` (home.init + adopt_db + ecto.migrate + health-check); then exec `mix phx.server`.
- **`docker/.dockerignore`** — exclude `_build`, `deps`, `node_modules`, the `/private/tmp/esr-*` worktrees, `.git`.

**Creds:** the image NEVER bakes credentials. Feishu creds + a claude/codex source login arrive via the read-only secrets mount; per-agent creds are provisioned during scenario steps by the existing `EzagentPluginCc.CredentialRefresh.provision/3` (PR-E) (and the codex analogue) — refresh-if-expired + copy into the per-agent config dir. (`feedback_self_generate_test_credentials`.)

**Deliverable (PR-1):** `docker compose -f docker/docker-compose.dev.yml up` → a blank, bootstrapped ESR reachable at `http://100.64.0.27:10042` (Tailscale, `feedback_remote_browser_ip`), Feishu WS connected.

### 4.B — scenario-as-steps framework

A **scenario** is an ordered list of named **steps**; each step performs actions against the running ESR via `Ezagent.Invocation.dispatch` (the same production path existing e2e tests use) and may assert.

- **`Ezagent.E2E.Step`** — `%Step{name, source_hash, run, assert}`. `run(ctx) -> {:ok, ctx} | {:error, reason}`; `assert(ctx) -> :ok | {:error, detail}` (optional).
- **`defstep` macro** — captures the step body's AST at compile time, computes `source_hash = sha256(Macro.to_string(ast))`, and stores it on the struct. This delivers Q3's "content-hash of step source" at **per-step granularity, automatically** (no manual version bumping; editing a step's body changes its hash).
- **`Ezagent.E2E.Scenario`** — `%Scenario{id, base, steps}`. `base` names a prerequisite scenario whose final layer is the starting point (scenario 0's base = blank). 
- **`ctx`** — a map threaded through steps carrying created URIs/tokens. Because a layer restore restarts the node (in-memory ctx is lost), the **ctx is persisted in the layer manifest** (§4.C) and reloaded on restore. Steps must treat ctx as their only cross-step channel (no hidden global state).
- **Driver** — `mix ezagent.e2e.run <scenario> [--resume | --from-step N | --fresh]`: resolve the start layer (§4.C), restore it, run the remaining steps (snapshotting after each), run asserts, report. flunk-style failure with expected-vs-seen.

**Determinism note (honest):** agent (claude/codex) output is non-deterministic. Step **assertions on agent content** must check structure/markers (e.g. the `telephone_hop` wrapper text, a sender URI), not exact prose. A snapshot taken *after* a model step caches that run's output, so resuming from it is deterministic; *re-executing* a model step re-rolls the output (acceptable — that's what invalidation means).

**Deliverable (PR-2):** the framework + **scenario 0** (blank → bootstrap → assert endpoint healthy → seed baseline admin user) runs top-to-bottom in the docker env; its final layer is the base.

### 4.C — snapshot layers + resume-resolver

- **Layer** = `tar(EZAGENT_HOME/<profile>)` + sidecar `manifest.json` = `{scenario_id, step_index, step_name, fp, ctx}`. Stored in a layer-cache dir (its own volume/host dir), keyed/named by `fp`.
- **Fingerprint chain:** `fp(-1) = sha256(scenario.base_fp <> env_image_id)`; `fp(N) = sha256(fp(N-1) <> step_N.source_hash)`. Including `env_image_id` invalidates all layers when the docker image (deps/CLIs) changes.
- **Resolver:** to run scenario up to target step T — compute `fp(0..T)`; find the **highest M ≤ T** with a cached layer whose `fp == fp(M)`; restore it (extract tar to the `$EZAGENT_HOME` volume + load `ctx` from manifest); run steps `M+1..T`, snapshotting after each. No match → start from `base` (or blank) at step 0.
- **Invalidation:** automatic. If step K's source changes, `fp(K..)` change, so cached layers ≥ K never match → recomputed. Stale layers are simply never selected (optional age-based GC; **no silent reuse of a non-matching layer**).
- **Restore mechanism:** the harness (control process, outside the BEAM) does: `docker compose stop esr` → wipe + extract layer tar into the `$EZAGENT_HOME` named volume → `docker compose start esr` → wait healthy. The node then **rehydrates Kinds from the restored DB/snapshots** — the cold-restart path, made solid by #557 + PR-4. PTY subprocesses (claude/codex) respawn on rehydrate/demand.

**Deliverable (PR-3):** layer pack/unpack + manifest + resolver + restore orchestration + `--resume`/`--from-step`; demonstrated by re-running an unchanged-prefix scenario and observing it skip to the right step.

## 5. Why the restore path is safe now

Restoring a layer = restart node + rehydrate from the restored `$EZAGENT_HOME`. This is exactly the cold-restart rehydration path hardened this cycle: PR-4 (state normalization, guard empty-over-good snapshot) + #557 (lazy-migrate legacy `claude_config_dir`). So "resume from layer N" rides a path that is already tested and live-validated.

## 6. Components & boundaries (for plan decomposition)

| Unit | Responsibility | Depends on |
|------|----------------|-----------|
| `docker/Dockerfile.dev`, `compose`, `entrypoint` | reproducible blank env | mix, CLIs |
| `Ezagent.E2E.Step` + `defstep` | one named, content-hashed action | — |
| `Ezagent.E2E.Scenario` | ordered steps + base | Step |
| `Ezagent.E2E.LayerStore` | pack/unpack tar + manifest, lookup by fp | filesystem |
| `Ezagent.E2E.Resolver` | chain-hash → pick start layer | LayerStore, Scenario |
| `Ezagent.E2E.EnvControl` | stop/start node + swap EZAGENT_HOME + wait healthy | docker compose |
| `mix ezagent.e2e.run` | wire driver + resolver + reporting | all above |

## 7. Two-tier observability

- **Tier 1 (programmatic, in docker, autonomous, CI-able):** steps assert via the production read path (`Ezagent.MessageStore.recent_in_session/2`, registry/state queries). flunk on failure; never `assert true`.
- **Tier 2 (live, manual Feishu):** the resolver fast-forwards to the **last pre-trigger layer** (all members seeded, rules wired, waiting for the `@mention`); a human sends the real `@传话游戏 <word>` in the bound Feishu group and observes; the harness polls the production read path for the `telephone_hop`-rendered round-trip (the existing `scenario_34_..._live_test.exs` already does this). agent-browser screenshot = manual Standard-3 evidence. Because the resolver jumps straight to the pre-trigger layer, the human step is quick + repeatable (no full re-seed).

## 8. Testing strategy (TDD)

- **Resolver/LayerStore unit tests** (the highest-value, pure logic): chain-hash computation; "edit step K invalidates ≥K, keeps <K"; highest-valid-layer selection; pack/unpack round-trip; manifest ctx persistence. Written test-first.
- **Scenario 0** is the first integration target (blank → healthy).
- **Scenario 34** ported as the worked example (PR-4/follow-on), exercising tier 1 (programmatic seed of the relay team via Invocation.dispatch) + tier 2 (manual Feishu trigger hook).
- Every distinct bug found gets a fast regression test (`feedback_e2e_failure_earns_unit_test`).

## 9. Risks / open questions (for the adversarial review to pressure-test)

1. **Restore = full node restart per layer hop** (seconds each). Acceptable: the win is skipping expensive step *re-execution* (agent spawns, model calls), not avoiding a BEAM reboot.
2. **`defstep` source-hash granularity** — hashing `Macro.to_string(ast)` ignores called-helper changes (a step that calls a helper whose body changes won't invalidate). Mitigation: keep step bodies self-contained, or fold a module-source hash into `env_image_id`. Flagged for review.
3. **ctx across restore** — solved by persisting ctx in the manifest; but ctx must be JSON-serializable (URIs/strings/maps, no PIDs). Steps must not stash live processes in ctx.
4. **Model non-determinism** — assertions tolerant (markers, not prose); layers cache a concrete run.
5. **Creds in docker** — mounted secret + provisioner; never baked; secret mount is read-only.
6. **Feishu inbound can't be faked for the TRUE gate** — hence tier 2 is explicitly manual; the spec does not claim full autonomy for the final hop.
7. **Layer store growth** — many scenarios × steps = many tarballs; needs age/scenario-scoped GC (out of scope for v1 beyond a documented `--gc`).

## 10. PR decomposition (hand-off to writing-plans)

- **PR-1 (A):** `Dockerfile.dev` + `compose.dev` + `entrypoint` + blank-bootstrap → `compose up` healthy.
- **PR-2 (B):** `Step`/`defstep`/`Scenario` + `mix ezagent.e2e.run` + **scenario 0** running top-to-bottom.
- **PR-3 (C):** `LayerStore` + `Resolver` + `EnvControl` + `--resume`/`--from-step`; resume-skips demonstrated.
- **PR-4 (follow-on):** port scenario 34 (relay) as the worked example incl. the tier-2 live hook.

## 11. Bilingual

Per `feedback_bilingual_docs_convention`, a `…-design.zh_cn.md` mirror will be created before the final Allen confirmation; the Chinese summary is what gets sent via Feishu.

## 12. Cross-references

- Cold-restart rehydration: PR-4, #557; memory `project_scenario34_e2e_bug_stack`.
- Scenario-34 doc + live harness: `docs/scenarios/34-sender-locked-relay/scenario.md`, `apps/ezagent_domain_chat/test/e2e/scenario_34_sender_locked_relay_live_test.exs`.
- Bootstrap/home: `mix ezagent.bootstrap`, `mix ezagent.home.init`.
- Standards: `feedback_e2e_in_docker_fresh_seed`, `feedback_e2e_faces_production`, `feedback_esr_e2e_standards`, `feedback_self_generate_test_credentials`, `feedback_remote_browser_ip`, `feedback_spec_codex_adversarial_review`.
