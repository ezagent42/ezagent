# Dockerized dev/test env + layered checkpointed E2E harness — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline) — infra + a live BEAM are hard to parallelize safely; execute sequentially with codex review per PR. Steps use `- [ ]`.

**Goal:** A dockerized dev/test ESR that starts blank, where E2E scenarios seed via the production paths, with cred-free snapshot layers + a resume-resolver — supporting cc/codex/curl. Reach a **tier2-testable** state (env up + relay seeded, awaiting a Feishu `@mention`).

**Architecture:** see SPEC `docs/superpowers/specs/2026-06-04-dockerized-e2e-harness-design.md` (codex-approved). A=docker env, B=scenario-step framework + scenario 0, PR-2b=codex provisioner, C=LayerStore/Resolver/EnvControl, PR-4=scenario 34.

**Tech Stack:** Elixir 1.19/OTP 28 umbrella, `mix phx.server` (dev), SQLite, Feishu WS, claude/codex/uv CLIs, Docker + compose.

**Branch:** `feat/dockerize-dev-test-e2e`. Each PR = own commit set; codex review; admin-merge to main.

**Priority for AFK window (tier2 ASAP):** PR-1 → PR-2b → (enough of B to seed scenario 34) → tier2 manual test. PR-3 (layer caching) is a speed optimization, after tier2 proven.

---

## File structure

```
docker/
  Dockerfile.dev              # multi-stage dev image (elixir+otp + claude/codex/uv + assets)
  docker-compose.dev.yml      # esr service, volumes (EZAGENT_HOME, secrets, cred sources, layers)
  entrypoint.sh               # bootstrap-if-blank → mix phx.server
  .dockerignore
  README.md                   # how to build/run + secrets layout
apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/credential_refresh.ex   # PR-2b
apps/ezagent_plugin_codex/test/ezagent/plugin_codex/credential_refresh_test.exs
apps/ezagent_core/lib/ezagent/e2e/
  step.ex                     # %Step{}, defstep macro (full-contract hash + @layer_inputs)
  scenario.ex                 # %Scenario{id, base, steps}
  manifest.ex                 # versioned schema + ctx encode/decode
  layer_store.ex              # pack/unpack tar (cred-exclude per credential_relpaths) + lookup
  resolver.ex                 # chain-hash → highest assert_passed layer
  env_control.ex              # stop/start node + swap EZAGENT_HOME + provision-hook + wait healthy
  runner.ex                   # drive run→await→assert→publish; preflight
apps/ezagent_core/lib/mix/tasks/ezagent.e2e.run.ex   # CLI
apps/ezagent_core/test/e2e/scenarios/scenario_0.ex   # scenario 0 (bring-up/bootstrap)
apps/.../test/.../e2e/scenarios/scenario_34.ex       # PR-4
```

---

## PR-1: dockerized dev/test environment

**Files:** Create `docker/Dockerfile.dev`, `docker/docker-compose.dev.yml`, `docker/entrypoint.sh`, `docker/.dockerignore`, `docker/README.md`.

Validation is integration-style (no unit tests for Dockerfiles); the "test" is `docker compose up` → healthy endpoint + agents work. Steps:

- [ ] **Step 1: `.dockerignore`** — exclude `_build`, `deps`, `node_modules`, `.git`, `/private/tmp`, `*.db`.
- [ ] **Step 2: `Dockerfile.dev`** — multi-stage:
  - Stage `base`: `FROM hexpm/elixir:1.19.<x>-erlang-28.<x>-debian-bookworm-<y>` (resolve exact tags from the host toolchain at build time).
  - Install OS deps: `git tar ca-certificates curl xz-utils` + Node LTS (for the claude npm pkg).
  - Install CLIs on PATH: `npm i -g @anthropic-ai/claude-code@<pin>`; install `codex` `<pin>` (npm `@openai/codex` or the release binary — resolve at build); install `uv` via the astral installer to `/usr/local/bin`.
  - `WORKDIR /app`; `COPY mix.exs mix.lock ./` + `COPY apps/*/mix.exs apps/*/` (umbrella) ; `mix local.hex --force && mix local.rebar --force && mix deps.get`.
  - `COPY . .`; `MIX_ENV=dev mix compile`; `mix assets.setup && mix assets.build`.
  - `ENV LANG=C.UTF-8`.
- [ ] **Step 3: `entrypoint.sh`** — `set -euo pipefail`; if `[ ! -f "$EZAGENT_HOME/$EZAGENT_PROFILE/db/ezagent_core.db" ]` then `mix ezagent.bootstrap`; seed the static feishu cred from the RO mount into `$EZAGENT_HOME/$EZAGENT_PROFILE/credentials/feishu.yaml` if absent; `exec elixir --name "esr@127.0.0.1" --cookie "$EZAGENT_COOKIE" -S mix phx.server`.
- [ ] **Step 4: `docker-compose.dev.yml`** — service `esr`: build `docker/Dockerfile.dev`; `ports: ["10042:10042"]`; `env_file`; environment `PORT=10042 EZAGENT_HOME=/data EZAGENT_PROFILE=default HTTP_PROXY/HTTPS_PROXY/NO_PROXY EZAGENT_COOKIE`; volumes: `esr_home:/data`, `./secrets:/secrets:ro` (feishu.yaml, cc/codex seed creds, deepseek key), `cred_cc:/cred/cc`, `cred_codex:/cred/codex`, `layers:/layers`; `healthcheck: curl -fsS http://localhost:10042/ || exit 1`.
- [ ] **Step 5: `README.md`** — secrets layout + `docker compose -f docker/docker-compose.dev.yml up --build`; note Tailscale `http://100.64.0.27:10042`.
- [ ] **Step 6: Build + bring up** — `docker compose -f docker/docker-compose.dev.yml build` then `up -d`; poll healthcheck; confirm `/` responds + Feishu WSS connects in logs. Iterate on build failures (missing CLI, asset step, deps).
- [ ] **Step 7: codex review** (`adversarial-review --base main`) → fix → admin-merge.

**Acceptance:** `docker compose up` → blank bootstrapped ESR at `:10042`, Feishu WSS connected, `claude`/`codex`/`uv` resolvable inside the container (`docker compose exec esr which claude codex uv`).

---

## PR-2b: codex credential provisioner (TDD — pure, do early; unblocks codex flavor)

**Files:** Create `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/credential_refresh.ex` + test. Modify `apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex` (impl `refresh_test_credentials/3`).

Mirrors `EzagentPluginCc.CredentialRefresh` but over a **CODEX_HOME dir** reproducing the FULL `credential_relpaths` (`auth.json` refresh-if-expired + `config.toml` copy). Crash-safe lock from the start (OS advisory lock on an open fd).

- [ ] **Step 1: failing test** `credential_refresh_test.exs` — mirror cc's test structure (injected `http_post` + `now_ms`):
  - non-expired `auth.json` source → copied as-is, `config.toml` copied, no refresh.
  - expired `auth.json` → refresh via injected post (assert codex token endpoint + grant), rotated token written back to source, both files in home, `auth.json` chmod 600.
  - missing `config.toml` in source → clear error (the full set must be reproducible).
  - refresh HTTP failure → error, source untouched.
- [ ] **Step 2: run → FAIL** (`mix test apps/ezagent_plugin_codex/test/ezagent/plugin_codex/credential_refresh_test.exs`).
- [ ] **Step 3: implement** `CredentialRefresh.provision(source_dir, home_dir, opts)` — read codex `auth.json` (tokens.access_token/refresh_token/expiry, `last_refresh`); if expired, POST refresh to the codex/OpenAI token endpoint (injectable), atomic write-back; copy every `CodexAgent.credential_relpaths()` entry into `home_dir` (chmod 600 on `auth.json`); OS-advisory-fd lock colocated in the source dir.
- [ ] **Step 4: run → PASS** + full `apps/ezagent_plugin_codex` suite green.
- [ ] **Step 5: wire** `CodexAgent.refresh_test_credentials/3` → delegate to the provisioner.
- [ ] **Step 6: commit + codex review + admin-merge.**

**Acceptance:** `CodexAgent` implements `refresh_test_credentials/3` reproducing the full CODEX_HOME credential set; tests green.

---

## PR-2: scenario-step framework + scenario 0

**Files:** Create `apps/ezagent_core/lib/ezagent/e2e/{step,scenario,manifest,runner}.ex`, `apps/ezagent_core/lib/mix/tasks/ezagent.e2e.run.ex`, `apps/ezagent_core/test/e2e/scenarios/scenario_0.ex` + unit tests.

Key interfaces (TDD each):
- `Ezagent.E2E.Step` + `defstep name, layer_inputs: [...], do:` capturing `run`/`await`/`assert` ASTs → `inputs_hash = sha256(run_ast<>await_ast<>assert_ast<>hash_each(layer_inputs))`. Unit test: identical bodies → same hash; tightening `await` only → different hash.
- `Ezagent.E2E.Scenario` — `%Scenario{id, base, steps}`; `fp_chain/1` computes `[fp(0)..fp(N)]`.
- `Ezagent.E2E.Manifest` — `encode/1`/`decode/1` (URIs→strings, caps rebuilt, ISO8601, primitives only); versioned. Unit test: post-decode a step's ctx yields `%URI{}` etc.
- `Ezagent.E2E.Runner` — per step `run → await → assert`; (layers come in PR-3; here run end-to-end without caching) ; flunk-style report.
- ingress driver helper — build a decoded Feishu event map + call `EzagentPluginFeishu.InboundDispatcher` (locate its public entry; add a thin test seam if needed).
- `scenario_0` — steps: bootstrap-assert-healthy; seed baseline admin user (via `Invocation.dispatch`).
- `mix ezagent.e2e.run <scenario>` — run a scenario top-to-bottom (no resume yet).

Commit per interface; codex review; admin-merge.

**Acceptance:** `mix ezagent.e2e.run scenario_0` (inside the container) runs green; framework unit tests green.

---

## PR-3: LayerStore + Resolver + EnvControl + 3-flavor restore

**Files:** Create `apps/ezagent_core/lib/ezagent/e2e/{layer_store,resolver,env_control}.ex` + tests; extend `runner.ex` (publish-after-assert) + `ezagent.e2e.run` (`--resume`/`--from-step`).

- `LayerStore.pack(home, exclude: credential_relpaths_union)` → tar excluding the full per-flavor `credential_relpaths`; `unpack/2`; `put/get` by `fp` + manifest. Unit test: packed tar contains NO `.credentials.json`/`auth.json`/`config.toml` (enumerate `credential_relpaths()`).
- `Resolver.start_layer(scenario, target, store)` → highest M with `fp==fp(M) ∧ assert_passed ∧ schema_version==current`. Unit tests: highest-valid selection; tightened await/assert rejects ≥-step; helper change rejects ≥-step; no-publish-before-assert.
- `EnvControl` — stop/start the compose `esr` service, swap `/data` (EZAGENT_HOME), run the **provision-hook** (per restored agent's flavor, call `refresh_test_credentials/3`; curl `put_api_key` from the deepseek secret), wait healthy. Layerability preflight (expiring-cred flavor must have a provisioner else fail-loud).
- Runner: `run → await → assert → atomic publish` (only on assert pass).

Commit per unit; codex review; admin-merge.

**Acceptance:** re-running an unchanged-prefix scenario skips to the right step; editing a helper rejects downstream layers; restore re-provisions cc+codex creds + curl key; crash-safe lock test passes.

---

## PR-4: port scenario 34 (the worked example) + tier2 hook

**Files:** Create `apps/ezagent_domain_chat/test/e2e/scenarios/scenario_34.ex` (or under e2e/scenarios); reuse the existing `scenario_34_..._live_test.exs` poll logic for tier2.

Steps (domain-setup + ingress, via the framework): create the cc/codex/curl relay members (the 8 orchestrator-tool calls as steps), define legend + rule-set + prompt template, bind a Feishu group → session, provision all three flavors' creds, **stop at the pre-trigger layer**. tier2 = manual Feishu `@传话游戏` + poll the production read path for the `telephone_hop`-rendered round-trip.

**Acceptance (tier2-testable):** the relay is seeded + bound in the docker env at the pre-trigger layer; Allen sends `@传话游戏 苹果`; the harness poll confirms the cc→codex→curl round-trip.

---

## Self-review notes
- Spec coverage: A→PR-1; B→PR-2; codex provisioner→PR-2b; C→PR-3; scenario 34→PR-4. All SPEC §s mapped.
- Risk: PR-1 docker build iteration is the long pole; kick it off first. PR-3 caching is deferrable past the first tier2 test.
- AFK fallback: if time-bound, deliver PR-1 + PR-2b + a direct scenario-34 seed (even pre-framework) to make tier2 testable, then backfill PR-2/PR-3 structure.
