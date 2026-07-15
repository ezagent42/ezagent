# Hello Fusion Reproducible Seed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one idempotent Mix command that reconstructs the complete committed Fusion website on an independent fresh database.

**Architecture:** A focused `FusionSeed` module owns loading and applying the committed Page/CSS through `App.ensure_app` and `TurnDriver`. The new Mix task and the existing boot-time `system/fusion` demo path call this module so they cannot drift.

**Tech Stack:** Elixir 1.19, OTP 28, ExUnit, Ezagent Session/Surface APIs, Mix tasks.

## Global Constraints

- The seed must not depend on the author's database, Session snapshots, or local state.
- `body.json` and `shell.css` are the only website-content sources.
- Use sanctioned Ezagent APIs; do not write snapshots, Surface rows, or caps directly.
- Missing or invalid full-site seed content must fail explicitly without a `Spec.seed()` fallback.
- Preserve unrelated dirty files in the working tree.

---

### Task 1: Shared Fusion seed service

**Files:**
- Create: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/fusion_seed.ex`
- Create: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/fusion_seed_test.exs`

**Interfaces:**
- Produces: `EzagentPluginHello.FusionSeed.run/0`
- Produces: `EzagentPluginHello.FusionSeed.run/1` accepting test overrides `:workspace`, `:name`, `:body_path`, and `:css_path`
- Returns: `{:ok, %{session_uri: URI.t(), turn_id: String.t()}} | {:error, term()}`

- [ ] Write a failing ExUnit test that starts without the target Session, calls `FusionSeed.run/1`, and asserts the exact Session URI plus committed Page/CSS state.
- [ ] Run `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/fusion_seed_test.exs` and confirm failure because `FusionSeed` does not exist.
- [ ] Implement `FusionSeed` with `Workspace.create`, `App.ensure_app`, `File.read`, `Jason.decode`, `Spec.validate`, `TurnDriver.drive`, and `TurnDriver.set_shell`.
- [ ] Add failing tests for missing body, invalid JSON, and missing CSS; confirm explicit errors and no fallback Page.
- [ ] Run the focused test file and confirm all cases pass.

### Task 2: Fusion Mix command and boot reuse

**Files:**
- Create: `apps/ezagent_plugin_hello/lib/mix/tasks/ezagent.demo.seed_hello_fusion.ex`
- Create: `apps/ezagent_plugin_hello/test/mix/tasks/ezagent_demo_seed_hello_fusion_test.exs`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex`

**Interfaces:**
- Produces: `mix ezagent.demo.seed_hello_fusion`
- Consumes: `FusionSeed.run/0`

- [ ] Write a failing Mix-task test asserting the task calls the Fusion seed contract and prints `session://system/hello/fusion` plus `/hello/fusion`.
- [ ] Run the task test and confirm failure because the task does not exist.
- [ ] Implement the Mix task with fail-loud `Mix.raise/1` error reporting.
- [ ] Replace the boot-time duplicated `seed_page/1` implementation for `system/fusion` with `FusionSeed.run/0`; retain generic demo behavior for other names.
- [ ] Run the Fusion seed tests and existing Hello demo/page integration tests.

### Task 3: Rebuild documentation and full verification

**Files:**
- Modify: `docs/guide/hello-rebuild-guide.md`

- [ ] Document the fresh-database command and explicitly distinguish it from the generic `mix ezagent.demo.seed_hello` basic seed.
- [ ] Run `mix format` on touched Elixir files only.
- [ ] Run the full `apps/ezagent_plugin_hello` test suite.
- [ ] Run `mix precommit` and fix only failures attributable to this change.
- [ ] Review `git diff`, confirm no credentials or unrelated dirty files are staged, and commit with Conventional Commits.
